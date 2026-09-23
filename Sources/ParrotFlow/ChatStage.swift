import AppKit
import SwiftUI

/// Measurements and colours for the chat window the tour's last two screens are
/// drawn in.
///
/// One size for the whole picture, and it is not life size. Slack draws its own
/// composer at 13, and at 13 the dictated line was half the box and a fifth of
/// the window — and it is the one thing on either screen somebody has to read.
/// The size is not a round figure: measured off the render, 23.5 gave the line
/// 90% of the box, 21.5 gave it 83%, and 19.5 gives it 77%.
enum Chat {
    static let text: CGFloat = 19.5

    /// Slack's own text size. Everything in the picture is written at this and
    /// drawn at `scale`, so the proportions are Slack's at any size.
    static let lifeSize: CGFloat = 13

    static var scale: CGFloat { text / lifeSize }

    /// Slack's own measurement for a 13pt line, drawn at `text`.
    static func s(_ points: CGFloat) -> CGFloat { points * scale }

    /// The face the line is set in, as an `NSFont`.
    ///
    /// Kept so the tour can work out where a word sits without asking the layout
    /// for it. See `ChatStage.callout`.
    static let font = NSFont.systemFont(ofSize: text)

    /// The composer's own height, so a callout can sit over the pill: it is the
    /// box, its padding, the toolbar and the gaps, and the lines in it.
    static var composerHeight: CGFloat {
        s(9) * 2 + s(14) + s(9) + lineHeight + s(11) + s(22)
    }

    /// How tall one line of it is, and the air under it.
    static var lineHeight: CGFloat { s(17) }
    static var lineGap: CGFloat { s(4) }

    /// From the top of the composer to the top of its first line: its own
    /// padding, the toolbar, and the air under the toolbar.
    static var firstLine: CGFloat { firstLine(at: text) }

    /// The same measurement for a composer built at another size. On `Chat` and
    /// not on `ChatComposerFrame`, which is generic and so has no static members
    /// of its own to reach from outside.
    static func firstLine(at size: CGFloat) -> CGFloat {
        (9 + 14 + 9) * size / lifeSize
    }

    /// Air inside the composer, left and right. Not scaled with the rest: at
    /// Slack's proportion for text this size the line would run to the edge of
    /// the box on one side and leave a hole on the other.
    static let inset: CGFloat = 20

    /// Slack's own link blue, and not the app's accent: the caret on this same
    /// line is that accent, and two blues meaning different things in one frame
    /// is what the tour cannot afford.
    static let link = Color(red: 0.35, green: 0.68, blue: 0.92)
    static let send = Color(red: 0.0, green: 0.478, blue: 0.353)
    static let sendDown = Color(red: 0.09, green: 0.62, blue: 0.45)

    /// What a selection is drawn in. Slack takes the system accent; this is that
    /// blue brought down far enough to sit on a dark field without glowing.
    static let selection = Color(red: 0.22, green: 0.42, blue: 0.64)

    /// How long the wash behind a word that has just changed takes to fade.
    ///
    /// The one thing on these screens the app does not do: words changing while
    /// nobody is looking at them is the easiest beat to miss, and a mark behind
    /// them is the cheapest way to say *there*.
    static let wash: TimeInterval = 0.9

    /// The room the channel above the composer keeps, when it has anything in it
    /// at all. See `ChatStage`.
    static var channel: CGFloat { 118 * scale }

    /// Air between the channel and the composer's top edge. A message resting on
    /// the box reads as part of it.
    static var channelGap: CGFloat { 12 * scale }

    /// The box the pill is laid out in. Every state either tour's pill takes is
    /// the tab, so this is the tab's size and not an offer's.
    static let reserved: NSSize = {
        let states: [PillState] = [.recording(nil), .working("Transcribing…")]
        let sizes = states.map {
            PillMetrics.panelSize(
                for: $0, hasIcon: true, hotkey: Tutorial.hotkey, dock: .below
            )
        }
        return NSSize(
            width: sizes.map(\.width).max() ?? 0,
            height: sizes.map(\.height).max() ?? 0
        )
    }()

    /// The tab's own height: its panel less the bloom's margin on both sides.
    static var tabHeight: CGFloat { reserved.height - 2 * PillMetrics.bleed }

    /// Air between the composer's bottom edge and the tab. Hung from the top of
    /// its own panel the tab would start a bloom's margin below the composer,
    /// which reads as a gap rather than as attached.
    static let tabGap: CGFloat = 5

    /// The one sentence a callout says, and the bubble it says it in.
    ///
    /// Bigger than anything else on the screen and the only light thing on it.
    /// A callout is not part of the window it points into — it is the tour
    /// talking — and a bubble that matched the surface it hangs over would read
    /// as something Slack drew.
    static let calloutText: CGFloat = 16
    static let bubble = Color(white: 0.93)

    /// The bubble's own padding, left and right.
    static var calloutInset: CGFloat { s(9) }

    /// The body of the bubble, less its tail.
    static var calloutBody: CGFloat {
        ceil(calloutText * 1.22) + s(7) * 2
    }

    /// How tall it is: one line of its text, its own padding, and the tail.
    ///
    /// Worked out and not measured. What it is positioned against arrives from
    /// the composer, and a measurement of the bubble itself would arrive a frame
    /// later — which is a callout that jumps on the frame it appears.
    static var calloutHeight: CGFloat {
        ceil(calloutText * 1.22) + s(7) * 2 + s(5)
    }

    /// Clamped, and in order.
    ///
    /// Clamping is what lets a sweep run off either end of a run of text, and
    /// sorting is what keeps two stops at the same place from being a hard edge
    /// in the wrong direction.
    static func stops(_ list: [(Double, Color)]) -> [Gradient.Stop] {
        list
            .map { (min(1, max(0, $0.0)), $0.1) }
            .sorted { $0.0 < $1.0 }
            .map { Gradient.Stop(color: $0.1, location: $0.0) }
    }
}

/// Where a callout points, and what it says.
struct ChatAnchor: Equatable {
    /// What the tail points at: a run of the line, or the keycap on the pill
    /// hanging under the composer.
    enum Target: Equatable {
        case run(line: Int, run: Int)
        case pill
    }

    var target: Target
    var text: String
}

/// One stretch of the composer's line.
///
/// A sentence is a handful of these rather than a string, because the two things
/// the tour does to a line — highlighting a selection and marking what just
/// changed — are both stretches of it, and neither is expressible in a string.
struct ChatRun: Equatable {
    enum Style {
        case plain
        /// A link, or a mention: the same blue, because Slack draws both that
        /// way and the tour has no reason to tell them apart.
        case link
    }

    var text: String
    var style: Style = .plain

    /// How much of this stretch is selected, 0 to 1. The highlight travels over
    /// the words rather than appearing: this is a person dragging over them.
    var selected: Double = 0

    /// How much wash is left on it, 0 to 1. See `Chat.wash`.
    var wash: Double = 0
}

/// Slack's composer, drawn.
///
/// Drawn and not pictured: this is where the words land and where the pill
/// hangs, and a screenshot would put both in the wrong place at every size.
/// The composer's own chrome: the toolbar above the words, the row of actions
/// under them, and the box around all of it.
///
/// Shared rather than copied. The vocabulary screen is the same composer with a
/// different line in it, and two drawings of one surface are two things to keep
/// in step. `size` is the size the whole chrome is measured at, so a screen
/// whose words are set smaller gets a composer built to that size rather than a
/// Slack one with small words in it.
struct ChatComposerFrame<Content: View>: View {
    var size: CGFloat = Chat.text
    /// The pointer is down on *Send*.
    var sending = false
    @ViewBuilder var content: Content

    /// One of Slack's own measurements, at this composer's size.
    private func s(_ points: CGFloat) -> CGFloat { points * size / Chat.lifeSize }

    /// The toolbar. Four marks, and only the four the tour has anything to do
    /// with: every other button Slack draws there is one this person will not
    /// press while reading a setup window, and a row of grey glyphs is a row the
    /// eye has to rule out before it finds the line underneath.
    ///
    /// Not a `static let`: a generic type cannot hold one.
    private var tools: [String] { ["bold", "italic", "underline", "strikethrough"] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            content.padding(.top, s(9))
            actions.padding(.top, s(11))
        }
        .padding(.horizontal, Chat.inset)
        .padding(.vertical, s(9))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: s(9), style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: s(9), style: .continuous)
                .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                Image(systemName: tool)
                    .font(.system(size: s(11)))
                    .foregroundStyle(Color.white.opacity(0.38))
                    .frame(width: s(19))
            }
            Spacer(minLength: 0)
        }
        .frame(height: s(14))
    }

    private var actions: some View {
        HStack(spacing: s(15)) {
            Image(systemName: "plus")
                .font(.system(size: s(11), weight: .medium))
                .frame(width: s(20), height: s(20))
                .background(Color.white.opacity(0.05), in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                }
            Spacer(minLength: 0)
            sendButton
        }
        .foregroundStyle(Color.white.opacity(0.45))
        .frame(height: s(22))
    }

    /// Two targets in one box, as Slack draws it: send, and the menu of other
    /// ways to send.
    private var sendButton: some View {
        HStack(spacing: 0) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: s(11)))
                .frame(width: s(31))
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 1, height: s(22))
            Image(systemName: "chevron.down")
                .font(.system(size: s(9), weight: .semibold))
                .frame(width: s(19))
        }
        .foregroundStyle(.white)
        .frame(height: s(22))
        .background(
            sending ? Chat.sendDown : Chat.send,
            in: RoundedRectangle(cornerRadius: s(6), style: .continuous)
        )
        .scaleEffect(sending ? 0.93 : 1)
    }
}

/// The composer the Slack screen is dictated into: the shared chrome, with the
/// lines of runs the words land on in it.
struct ChatComposer: View {
    /// One empty line when there is nothing in it, so the box is the height it
    /// will be once the words land. A composer that grew as the words arrived
    /// moved the pill and the pane under it on the frame they landed.
    private var rows: [[ChatRun]] { lines.isEmpty ? [[]] : lines }

    /// The composer holds lines of runs, and not one run of them: a sentence in
    /// Slack wraps, and a tour that draws one long line to the edge of the box
    /// and puts an ellipsis on the end of it is showing a sentence being lost.
    ///
    /// The break is the tour's to make. Every sentence here is fixed, and Slack
    /// breaks at a word boundary, which is where these break too.
    let lines: [[ChatRun]]
    /// Where the caret goes: the line, and the run within it that it follows.
    /// Nil is no caret, which is what a line with something selected on it has.
    var caret: (line: Int, run: Int)?
    /// The pointer is down on *Send*.
    var sending = false
    /// Which runs of the line say where they are, so a screen can dim round
    /// them. Indexes into the first line, which is the only line either tour
    /// dictates into. See `TourSpot`.
    var lit: Set<Int> = []

    var body: some View {
        ChatComposerFrame(sending: sending) { text }
    }

    /// The lines the words land on, and the caret they land at.
    private var text: some View {
        VStack(alignment: .leading, spacing: Chat.lineGap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { number, runs in
                HStack(spacing: 0) {
                    ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                        if caret?.line == number, caret?.run == index { caretMark }
                        piece(run)
                            .anchorPreference(key: TourSpot.self, value: .bounds) {
                                number == 0 && lit.contains(index)
                                    ? [.init(box: $0, soft: true)] : []
                            }
                    }
                    if caret?.line == number, caret?.run == runs.count { caretMark }
                    Spacer(minLength: 0)
                }
                .frame(height: Chat.lineHeight, alignment: .leading)
            }
        }
        .font(.system(size: Chat.text))
    }

    private var caretMark: some View {
        Rectangle()
            .fill(Parrot.action)
            .frame(width: Chat.s(1.5), height: Chat.s(15))
    }

    /// One stretch of a line.
    ///
    /// A stretch with nothing behind it is drawn as bare text: the padding that
    /// gives a mark room to clear the glyphs is a fraction of a point out by the
    /// time it is put back, and a line that has not changed should be laid out
    /// exactly as the words are.
    @ViewBuilder private func piece(_ run: ChatRun) -> some View {
        let text = Text(run.text)
            .foregroundStyle(run.style == .plain ? Color(white: 0.88) : Chat.link)

        if run.selected > 0 {
            // Tight to the words, which is how a selection is drawn, and it is
            // the difference that keeps the comma after a selected name out of
            // the highlight.
            text.background { RoundedRectangle(cornerRadius: Chat.s(2)).fill(selection(run)) }
        } else if run.wash > 0 {
            text
                .padding(.horizontal, Chat.s(3))
                .background {
                    RoundedRectangle(cornerRadius: Chat.s(3), style: .continuous)
                        .fill(Chat.link.opacity(0.30 * run.wash))
                }
                .padding(.horizontal, -Chat.s(3))
        } else {
            text
        }
    }

    /// The highlight, dragged over the words from the left.
    ///
    /// Kept flat and then cut rather than faded: what moves with a drag is the
    /// edge, not the strength.
    private func selection(_ run: ChatRun) -> LinearGradient {
        LinearGradient(
            stops: Chat.stops([
                (0, Chat.selection),
                (run.selected - 0.03, Chat.selection),
                (run.selected, .clear),
                (1, .clear),
            ]),
            startPoint: .leading, endPoint: .trailing
        )
    }
}

/// A message in the channel.
struct ChatMessage: View {
    let runs: [ChatRun]

    var body: some View {
        HStack(alignment: .top, spacing: Chat.s(8)) {
            Circle()
                .fill(Color.white.opacity(0.13))
                .frame(width: Chat.s(24), height: Chat.s(24))
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: Chat.s(11)))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            VStack(alignment: .leading, spacing: Chat.s(2)) {
                Text("You")
                    .font(.system(size: Chat.s(12), weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                HStack(spacing: 0) {
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        Text(run.text)
                            .foregroundStyle(
                                run.style == .plain ? Color(white: 0.88) : Chat.link
                            )
                    }
                }
                // A step under the composer's line, and not because it should be
                // smaller: this row spends its first inch on an avatar, and the
                // same sentence at the composer's size has nowhere to go but an
                // ellipsis.
                .font(.system(size: Chat.s(12)))
            }
            Spacer(minLength: 0)
        }
    }
}

/// The picture both chat tours are drawn in: whatever is in the channel above,
/// the composer, and the room the pill hangs in.
///
/// Shared rather than copied. The two screens are the same window with a
/// different line in it, and two drawings of a Slack composer would be two
/// things to keep in step.
struct ChatStage<Channel: View>: View {
    let lines: [[ChatRun]]
    var caret: (line: Int, run: Int)?
    var sending = false
    let pill: PillState?
    let level: Double
    /// Which chip the pointer is on, if any.
    var clicked: Int?
    /// The other end of a live pill frame morph, and how far the tour has
    /// travelled from it. Nil/one is an ordinary resting surface.
    var pillMorphFrom: PillState?
    var pillMorphTo: PillState?
    var pillMorphProgress: Double = 1
    var pillScalesMorphSource = false
    /// How much light is crossing the key on the pill, 0 for none.
    ///
    /// Drawn here and not by the pill. The pill is the app's own surface and the
    /// app has no state for a key being held — which is the honourable reason
    /// and not the real one: a light over the key is a thing a tour does, and it
    /// should stay where the tour can take it out again.
    var shimmer: Double = 0
    /// The room the channel keeps whatever is in it, so the composer is in the
    /// same place for the whole loop. A composer that moved down when a message
    /// appeared would be the tour jumping, and a stage that keeps room for
    /// something that never comes is a screen that ends in a gap.
    var channelHeight: CGFloat = 0
    /// The box the pill is laid out in, over every state this stage shows. The
    /// tab is the default; a stage whose offer opens into a panel of chips
    /// reserves the panel, or the panel would grow over the pane under it.
    var reserved: NSSize = Chat.reserved
    /// The room under the composer the pill hangs in, and anything that has to
    /// fit under the pill with it. See `Chat.pillRoom`.
    var room: CGFloat = Chat.tabHeight + Chat.tabGap
    /// The callout that is up, if any.
    var anchor: ChatAnchor?
    /// What says where it is, so a screen can dim round it: runs of the line,
    /// the surface, the callout. See `TourSpot`.
    var lit: Set<Int> = []
    var litSurface = false
    var litCallout = false
    @ViewBuilder var channel: Channel

    var body: some View {
        VStack(spacing: 0) {
            channel
                .frame(height: channelHeight, alignment: .bottom)
                .frame(maxWidth: .infinity, alignment: .leading)
            ChatComposer(lines: lines, caret: caret, sending: sending, lit: lit)
            pillRoom
        }
        .overlay { GeometryReader { proxy in bubble(in: proxy.size) } }
    }

    /// How much further right the surface is drawn than the box it sits in.
    ///
    /// The box is the widest state this stage shows and the surface is whichever
    /// one is up, so a surface narrower than its box is centred in it — which
    /// puts the tab a long way in from the composer's edge instead of under the
    /// caret. Taken back out here rather than in `TourPill`, where the
    /// vocabulary tour wants the centring.
    private func pillSize(for state: PillState) -> NSSize {
        let target = PillMetrics.panelSize(
            for: pillMorphTo ?? state, hasIcon: true,
            hotkey: Tutorial.hotkey, dock: .below
        )
        guard let pillMorphFrom else { return target }
        let source = PillMetrics.panelSize(
            for: pillMorphFrom, hasIcon: true, hotkey: Tutorial.hotkey, dock: .below
        )
        let progress = CGFloat(min(1, max(0, pillMorphProgress)))
        return NSSize(
            width: source.width + (target.width - source.width) * progress,
            height: source.height + (target.height - source.height) * progress
        )
    }

    private func slack(for state: PillState) -> CGFloat {
        let size = pillSize(for: state)
        return max(0, (reserved.width - size.width) / 2)
    }

    /// Where the bottom of the pill is, from the top of the stage.
    private var pillBottom: CGFloat {
        channelHeight + Chat.composerHeight + room
    }

    /// The callout, over the run it is about.
    ///
    /// Where that run is, is worked out from the text and the font rather than
    /// reported by the composer. A frame that arrives through a preference
    /// arrives with the layout before it, and this was pointing at the word
    /// beside the one it was about: the second callout was drawing over the link
    /// instead of over the handle.
    @ViewBuilder private func bubble(in size: CGSize) -> some View {
        if let anchor {
            let width = bubbleWidth(anchor.text)
            let wanted = middle(of: anchor)
            // The bubble is kept inside the pane and the tail is kept over the
            // word. What gives is where the tail sits inside the bubble, and not
            // which word it points at — clamping the bubble's middle instead
            // pushed this one a third of its own width off the handle and onto
            // the link beside it.
            let centre = min(
                max(wanted, width / 2), max(width / 2, size.width - width / 2)
            )
            let tail = min(
                max(wanted - (centre - width / 2), Chat.s(16)),
                max(Chat.s(16), width - Chat.s(16))
            )
            // Under the pill, over everything else. A callout on the pill placed
            // above it covers the composer, which is the thing the pill is
            // hanging off and the thing being read.
            let under = anchor.target == .pill
            ZStack(alignment: under ? .top : .bottom) {
                VStack(spacing: 0) {
                    if under {
                        ChatTail()
                            .fill(Chat.bubble)
                            .frame(width: Chat.s(11), height: Chat.s(5))
                            .rotationEffect(.degrees(180))
                            .offset(x: tail - width / 2)
                    }
                    Text(anchor.text)
                        .font(.system(size: Chat.calloutText))
                        .foregroundStyle(Color(white: 0.10))
                        .frame(width: width, height: Chat.calloutBody)
                        .background(
                            Chat.bubble,
                            in: RoundedRectangle(
                                cornerRadius: Chat.s(7), style: .continuous
                            )
                        )
                    Color.clear.frame(height: under ? 0 : Chat.s(5))
                }
                if !under {
                    ChatTail()
                        .fill(Chat.bubble)
                        .frame(width: Chat.s(11), height: Chat.s(5))
                        .offset(x: tail - width / 2)
                }
            }
            .frame(width: width, height: Chat.calloutHeight)
            // Soft, unlike the surface: this box is the bubble plus its tail
            // and the few points under it, so a hard edge on it would draw a
            // rectangle a little below a triangle.
            .anchorPreference(key: TourSpot.self, value: .bounds) {
                litCallout ? [.init(box: $0, soft: true)] : []
            }
            .position(
                x: centre,
                y: under
                    ? pillBottom + Chat.s(5) + Chat.calloutHeight / 2
                    : top(of: anchor) - Chat.s(5) - Chat.calloutHeight / 2
            )
        }
    }

    /// How wide a bubble is: its text at the size it is set in, and its own
    /// padding. Worked out rather than measured, for the reason above.
    private func bubbleWidth(_ text: String) -> CGFloat {
        width(of: text) + Chat.calloutInset * 2
    }

    /// The middle of the run a callout points at, measured from the left of the
    /// line.
    private func middle(of anchor: ChatAnchor) -> CGFloat {
        switch anchor.target {
        case .pill:
            // The light is drawn by the pill itself. Nothing points here.
            return Chat.inset
        case .run(let line, let run):
            let row = lines.indices.contains(line) ? lines[line] : []
            var left = Chat.inset
            for run in row.prefix(run) { left += width(of: run.text) }
            guard row.indices.contains(run) else { return left }
            return left + width(of: row[run].text) / 2
        }
    }

    /// The top of a line, measured from the top of the stage.
    private func top(of anchor: ChatAnchor) -> CGFloat {
        switch anchor.target {
        case .pill:
            // The tab's own top, which is where the bubble's tail stops.
            return channelHeight + Chat.composerHeight + Chat.tabGap
        case .run(let line, _):
            return channelHeight + Chat.firstLine
                + CGFloat(line) * (Chat.lineHeight + Chat.lineGap)
        }
    }

    private func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: Chat.font]).width
    }

    /// The pill hangs off the bottom of the composer, the way it hangs off the
    /// bottom of the line in the vocabulary tour.
    ///
    /// On the caret and not in the middle: the caret a pill hangs off is at the
    /// start of the line in both tours, whether the composer is empty or has the
    /// first two words selected. Its panel carries the bloom's margin on every
    /// side, so it is pulled back by that margin and let into the composer's
    /// own: the tab then starts where the caret does.
    ///
    /// Only the room the surface needs is reserved, and not the whole panel it
    /// is laid out in: the panel is the surface plus the bloom's margin on every
    /// side, and a screen whose bottom half is one gap is a screen that looks
    /// unfinished. The panel is drawn at its own size regardless — it is placed
    /// and not laid out.
    private var pillRoom: some View {
        ZStack(alignment: .topLeading) {
            // Always here, so the pane below it does not move when the pill comes
            // and goes.
            Color.clear.frame(height: room)
            if let state = pill {
                TourPill(
                    state: state, level: level, clicked: clicked,
                    morphFrom: pillMorphFrom,
                    morphTo: pillMorphTo,
                    morphProgress: pillMorphProgress,
                    scalesMorphSource: pillScalesMorphSource,
                    reserved: reserved, sheen: shimmer, lit: litSurface
                )
                // Every state hangs from the same corner: the surface's own
                // margin, not the widest one's. The offer is drawn with the
                // small margin and a dictation with the wide one, so using one
                // number for both put the post-dictation tab forty points above
                // the dictation one it is supposed to replace.
                .offset(
                    x: Chat.inset - PillMetrics.bleed(for: state)
                        - slack(for: state),
                    y: Chat.tabGap - PillMetrics.bleed(for: state)
                )
                .frame(height: room, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// The point of a callout: a triangle turned to hang off the bottom of a bubble.
private struct ChatTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
