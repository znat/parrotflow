import AppKit
import SwiftUI

/// The last tour: one Slack message, and the two things ParrotFlow does to it.
///
/// The two chat screens were one screen each — a PR number becoming a link, and
/// a name becoming a handle — and they are one message with both done to it. The
/// dictation is the vocabulary tour's dictation, so those timings are read off
/// `Tutorial` rather than written again.
enum TutorialSlack {

    /// How long a caption takes to wipe in from the left.
    ///
    /// There is no caption at the top of this screen. The message comes first —
    /// it is what the screen is about — and what the message is doing arrives
    /// underneath it once there is something to say.
    static let reveal: TimeInterval = 0.3

    /// Where the words land, counted from the top of the pass.
    static var landsAt: TimeInterval { Tutorial.landsAt }

    /// Where each step of the example begins, in seconds from the words landing.
    enum Beat: TimeInterval, CaseIterable {
        /// The sentence, whole, in the composer, already carrying its link, and
        /// the pill is back as a tab. Nothing is left for the app to do to the
        /// words: the table ran on the transcript before it was written, and the
        /// offer is what the app does next.
        case landed = 0.0
        /// `PR 478` is a link. Nothing was typed: a table replaced two words,
        /// which is the whole of what the app did.
        /// The callout on the link, for two seconds, before the second half
        /// starts. It is the whole of what the first half taught, and it is read
        /// on its own rather than during what comes next.
        case captioned = 0.4
        /// The key on the tab is lit and the light crosses it, for as long as it
        /// takes to see. It is how the tab becomes the panel, and it is said on
        /// the key rather than beside it: a callout over the composer covered the
        /// thing it was talking about.
        case shimmering = 4.66
        /// The tab is the panel.
        case opening = 6.06
        /// The pointer goes down on *Slack mentions*, and stays there. Long
        /// enough to read both chips and to see which one is being taken,
        /// because that choice is the lesson.
        case clicking = 6.86
        /// The name is a handle.
        case handled = 8.26
        /// The pointer goes down on *Send*. It has to be seen to be pressed —
        /// the message arriving on its own would say the app sent it.
        case sending = 9.46
        /// The composer is empty and the message is in the channel above it,
        /// with the repository's preview under it. One beat and not two: the
        /// preview is Slack's answer to a message that was just sent, and it
        /// arrives with it.
        case posted = 9.96

        /// Which step a time inside the example falls in.
        static func at(_ local: TimeInterval) -> Beat {
            allCases.last { local >= $0.rawValue } ?? .landed
        }
    }

    /// How long the drag over the name takes.
    static let dragging: TimeInterval = 0.48

    /// The beat between the drag landing and the light starting, so the two are
    /// not one movement.
    static let settle: TimeInterval = 0.2

    /// The whole example, and then a beat to read the preview before the loop
    /// starts again.
    static let example: TimeInterval = 12.5
    static var total: TimeInterval { landsAt + example }

    /// How long the preview takes to arrive. It starts with the message: the
    /// two are one answer to one send.
    static let arriving: TimeInterval = 0.32

    /// The sentence, and the pieces of it that change.
    ///
    /// `Alex’s` and not `Alex'`. Both are written; the apostrophe alone is older
    /// and is now mostly a newspaper habit, and this is a screen about a tool
    /// that corrects people's writing.
    ///
    /// One line, and it fills 96% of the composer. The second sentence was cut
    /// to keep it that way: two lines gave the callouts more room to be about
    /// than the message needed.
    static let title = "Dictations shaped around your work"

    /// The two callouts, which take turns pointing at the words they are about.
    ///
    /// The first is what somebody would have to be told. The second is what they
    /// could not have guessed: nobody said the handle, and it is right, because
    /// the mapping is theirs and lives in their config.
    static let caption = "Say a PR number and you get a link."

    /// How long the callout on the link stays up, and how long nothing happens
    /// for after it has gone. Both are read twice: once for what is on screen and
    /// once for when the next step may start.
    static let callout: TimeInterval = 2.0
    static let pause: TimeInterval = 1.5

    /// Where the key's middle is, across the tab, in the composer's coordinates.
    ///
    /// The tab is the bird and the key side by side: about three times as wide as
    /// it is tall, with the key in the right third of it. Measuring this off the
    /// tab's height put the light over the bird.
    static var keyCentre: CGFloat {
        let closed = PillState.offer(chips, nil, Confidence.Reading(), open: false)
        let panel = PillMetrics.panelSize(
            for: closed, hasIcon: true, hotkey: Tutorial.hotkey, dock: .below
        )
        return Chat.inset + (panel.width - 2 * PillMetrics.bleed(for: closed)) * 0.69
    }

    /// How long the light over the key takes, and it crosses once. Long enough
    /// to read as light and short enough that the hand does not wait for it.
    static let shimmering: TimeInterval = 1.4
    static let opening = "Hey "
    static let name = "Siobhan"
    /// The handle is not the name and not a tidying of it: it is the one you
    /// were given, which is the whole reason the mapping has to be in your
    /// config and cannot be worked out.
    static let mention = "@Sio"
    static let middle = ", Alex’s "
    static let spoken = "PR 478"
    static let label = "#478"
    static let rest = " needs one more review."

    /// The repository is not this repository. The URL in `github_refs` is the
    /// one the person configured, so a tour that showed a real one would be
    /// showing somebody else's config.
    static let repo = "acme/api"
    static let request = "Retry webhooks with backoff"

    /// What the offer says can be done about the sentence just dictated.
    ///
    /// Two, and both are real: `grammar` is the one shipped transform that asks
    /// for a place, and `slack_mentions` is the one the screen goes on to use.
    static let chips = [
        OfferedCommand(title: "Fix Grammar", key: "G"),
        OfferedCommand(title: "Slack mentions", key: "S"),
    ]

    /// The chip the pointer goes down on. One, and not zero: the screen is about
    /// the second one, and a click on the first would say otherwise.
    static let chosen = 1

    /// The tallest surface this screen shows, which is the panel with both
    /// chips on it.
    static var surfaceHeight: CGFloat { reserved.height - 2 * PillMetrics.bleed(for: .offer([], nil, Confidence.Reading(), open: true)) }

    /// What the stage keeps under the composer: the panel, the air above it, and
    /// the callout that points at the key — which hangs under the pill so it
    /// does not cover the composer.
    static var room: CGFloat {
        surfaceHeight + Chat.tabGap + Chat.calloutHeight + Chat.s(5)
    }

    /// The widest the pill gets, which is the panel with both chips on it, and
    /// the box the stage reserves for it.
    static let reserved: NSSize = {
        let states: [PillState] = [
            .recording(nil),
            .offer(chips, nil, Confidence.Reading(), open: true),
        ]
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
}

/// What the slack tour is doing at one moment.
struct TutorialSlackRun: Equatable {
    /// Seconds into one pass.
    let t: TimeInterval
    /// Seconds since this screen's demonstration started. The way on waits for
    /// it, and `t` wraps, so it cannot answer that.
    let elapsed: TimeInterval

    init(_ elapsed: TimeInterval) {
        self.elapsed = elapsed
        let total = TutorialSlack.total
        guard total > 0 else { t = 0; return }
        let wrapped = elapsed.truncatingRemainder(dividingBy: total)
        t = wrapped < 0 ? wrapped + total : wrapped
    }

    /// Whether the demonstration has played once through. See
    /// `TutorialRun.finished`.
    var finished: Bool { elapsed >= TutorialSlack.total }

    /// The dictation, read off this pass's own clock.
    ///
    /// Not through `TutorialRun`, which wraps at the vocabulary tour's length.
    /// This pass is nearly twice that, so borrowing its clock started a second
    /// dictation in the middle of the first one's example: the composer emptied,
    /// and the words then landed again already carrying the handle — with the
    /// callout that says so never getting its turn.
    private var listening: Bool {
        t >= Tutorial.leadIn && t < Tutorial.leadIn + Tutorial.held
    }

    private var settling: Bool {
        t >= Tutorial.leadIn + Tutorial.held && t < Tutorial.landsAt
    }

    /// The level the meter is fed. A curve, not a microphone: the tour is
    /// silent, because a setup window that makes noise before anyone asked it to
    /// is a window people close.
    var level: Double {
        guard listening else { return 0.18 }
        let u = t - Tutorial.leadIn
        let wave = abs(sin(u * 3.1)) * (0.65 + 0.35 * sin(u * 7.7))
        return min(1, max(0.18, 0.22 + 0.78 * wave))
    }

    /// The callout that is up, if any: the run it points at and what it says.
    ///
    /// One callout on this screen, on the link. There is no second one: what
    /// the app knew about the handle is not a sentence, it is the handle.
    /// How much light is crossing the key on the pill: 0 as it starts, 1 as it
    /// leaves, and nothing before or after the second it takes.
    var keyShimmer: Double {
        guard let local else { return 0 }
        let from = local - TutorialSlack.Beat.shimmering.rawValue
        guard from >= 0, from < TutorialSlack.shimmering else { return 0 }
        return from / TutorialSlack.shimmering
    }

    var anchor: ChatAnchor? {
        guard let local else { return nil }
        if local >= TutorialSlack.Beat.captioned.rawValue,
           local < TutorialSlack.Beat.captioned.rawValue + TutorialSlack.callout {
            return ChatAnchor(
                target: .run(line: 0, run: 3), text: TutorialSlack.caption
            )
        }
        return nil
    }

    /// One stretch of the pass the screen dims over, and what stays lit.
    ///
    /// Two of them, which are the screen's two lessons. The link, while the
    /// callout is up saying what happened to it — the callout is lit with it,
    /// because a sentence about the link is no use dimmed. Then the mention,
    /// from the drag over the name to the send: the name, and the surface that
    /// offers to rewrite it.
    ///
    /// Counted from the words landing, like every other beat here.
    static var lighting: [(from: TimeInterval, to: TimeInterval, runs: Set<Int>, surface: Bool, callout: Bool)] {
        let captioned = TutorialSlack.Beat.captioned.rawValue
        return [
            (
                from: TutorialSlack.landsAt + captioned,
                to: TutorialSlack.landsAt + captioned + TutorialSlack.callout,
                runs: [3], surface: false, callout: true
            ),
            (
                from: TutorialSlack.landsAt + captioned + TutorialSlack.callout
                    + TutorialSlack.pause,
                to: TutorialSlack.landsAt + TutorialSlack.Beat.sending.rawValue,
                runs: [1], surface: true, callout: false
            ),
        ]
    }

    private var lighting:
        (from: TimeInterval, to: TimeInterval, runs: Set<Int>, surface: Bool, callout: Bool)?
    {
        TutorialSlackRun.lighting.first { t >= $0.from && t < $0.to }
    }

    /// How far the rest of the screen is down, nought to one.
    var spotlight: Double {
        guard let lighting else { return 0 }
        let up = (t - lighting.from) / Tutorial.dimming
        let down = (lighting.to - t) / Tutorial.dimming
        return min(1, max(0, min(up, down)))
    }

    var lit: Set<Int> { lighting?.runs ?? [] }
    var litSurface: Bool { lighting?.surface ?? false }
    var litCallout: Bool { lighting?.callout ?? false }

    /// Seconds since the words landed, or nil before they did.
    private var local: TimeInterval? {
        guard t >= TutorialSlack.landsAt else { return nil }
        return t - TutorialSlack.landsAt
    }

    private var beat: TutorialSlack.Beat? { local.map(TutorialSlack.Beat.at) }

    /// The words are still in the composer. False before they land, because an
    /// empty composer with a caret in it is the state the key is held in.
    private var composing: Bool {
        guard let local else { return false }
        return local < TutorialSlack.Beat.posted.rawValue
    }

    /// The table has replaced the spoken words with a link.
    /// The name is a mention.
    private var handled: Bool { reached(.handled) }

    /// Whether the example has got as far as this step.
    private func reached(_ step: TutorialSlack.Beat) -> Bool {
        (local ?? -1) >= step.rawValue
    }

    /// How much of the wash is left on something that changed at this step.
    private func wash(since step: TutorialSlack.Beat) -> Double {
        guard let local else { return 0 }
        let over = local - step.rawValue
        guard over >= 0 else { return 0 }
        return max(0, 1 - over / Chat.wash)
    }

    /// How far the drag over the name has come, 0 to 1.
    ///
    /// The drag happens while the panel is open, which is where the app's own
    /// flow puts it: the offer is up for seconds and the pointer goes back to
    /// the words in the meantime.
    private var selecting: Double {
        guard let local else { return 0 }
        let start = TutorialSlack.Beat.captioned.rawValue
            + TutorialSlack.callout + TutorialSlack.pause
        let over = local - start
        guard over > 0 else { return 0 }
        return min(1, over / TutorialSlack.dragging)
    }

    /// What the pill is doing, or nil while it is off screen.
    ///
    /// Three things in one pass: the dictation, then the tab the app leaves after
    /// every dictation, then that tab opened into what it can do about the
    /// words. The offer is the app's own answer to "what now", and no other
    /// screen shows it.
    var pill: PillState? {
        if let beat {
            let panel = PillState.offer(
                TutorialSlack.chips, nil, Confidence.Reading(),
                open: beat.rawValue >= TutorialSlack.Beat.opening.rawValue
            )
            switch beat {
            case .landed, .captioned, .shimmering,
                 .opening, .clicking:
                // The offer is up from the moment the words land, which is what
                // the app does after every dictation.
                return panel
            case .handled, .sending, .posted:
                // Taken, and gone: a command that has run closes the offer.
                return nil
            }
        }
        if listening { return .recording(nil) }
        if settling { return .working("Transcribing…") }
        return nil
    }

    /// Which chip the pointer is on.
    ///
    /// Lit from the moment it is pressed until the command has run, and not for
    /// a frame at one instant: this is the click the screen exists to show.
    var clicked: Int? {
        guard let local else { return nil }
        let down = TutorialSlack.Beat.clicking.rawValue
        guard local >= down, local < TutorialSlack.Beat.handled.rawValue else {
            return nil
        }
        return TutorialSlack.chosen
    }

    /// The send button is down.
    var sending: Bool { beat == .sending }

    /// The message is in the channel.
    var posted: Bool { reached(.posted) }

    /// The preview shows with the message and not after it.
    var unfurled: Bool { posted }

    /// How far the preview has arrived: 0 as it starts, 1 once it is placed.
    var arriving: Double {
        guard let local else { return 0 }
        let over = local - TutorialSlack.Beat.posted.rawValue
        guard over >= 0 else { return 0 }
        return min(1, over / TutorialSlack.arriving)
    }

    /// The line, as the pieces the composer draws.
    var lines: [[ChatRun]] {
        let opening = ChatRun(text: TutorialSlack.opening)
        let middle = ChatRun(text: TutorialSlack.middle)
        let rest = ChatRun(text: TutorialSlack.rest)

        guard composing else { return [] }

        let name = handled
            ? ChatRun(
                text: TutorialSlack.mention, style: .link,
                wash: wash(since: .handled)
            )
            : ChatRun(text: TutorialSlack.name, selected: selecting)
        // The link is there as the words land and not a beat later: the table
        // runs on the transcript before it is written, so there is no frame in
        // which the number is spelled out and the link is not.
        let ref = ChatRun(text: TutorialSlack.label, style: .link)

        return [[opening, name, middle, ref, rest]]
    }

    /// Where the caret is, or nil while something is selected: a selection has no
    /// caret in it.
    var caret: (line: Int, run: Int)? {
        guard composing else { return nil }
        // After the words that were written, which is where a substitution
        // leaves it.
        if handled { return (0, 2) }
        guard selecting == 0 else { return nil }
        // Nothing is selected yet, so the caret is at the end of the sentence —
        // or at the start of an empty one, before the words land.
        return (0, lines.first?.count ?? 0)
    }

    /// The same line as it stands in the channel, once it has been sent.
    var sent: [ChatRun] {
        [
            ChatRun(text: TutorialSlack.opening),
            ChatRun(text: TutorialSlack.mention, style: .link),
            ChatRun(text: TutorialSlack.middle),
            ChatRun(text: TutorialSlack.label, style: .link),
            ChatRun(text: TutorialSlack.rest),
        ]
    }
}

/// The screen the slack tour plays on.
struct TutorialSlackPane: View {
    let run: TutorialSlackRun
    /// The downloads, for the bar under the header.
    var progress: Double?
    var fetching: String?

    var body: some View {
        TutorialScreen(
            title: TutorialSlack.title,
            lead: "",
            showsLead: false,
            progress: progress,
            fetching: fetching
        ) {
            stage
        }
        .tourSpotlight(run.spotlight)
    }

    private var stage: some View {
        ChatStage(
            lines: run.lines, caret: run.caret, sending: run.sending,
            pill: run.pill, level: run.level, clicked: run.clicked,
            shimmer: run.keyShimmer,
            channelHeight: Chat.channel,
            reserved: TutorialSlack.reserved,
            room: TutorialSlack.room,
            anchor: run.anchor,
            lit: run.lit, litSurface: run.litSurface, litCallout: run.litCallout
        ) {
            channel
        }
    }

    /// What is above the composer. Empty until the message goes, and filled
    /// upward from the bottom, which is the direction a channel fills.
    private var channel: some View {
        VStack(alignment: .leading, spacing: Chat.s(10)) {
            Spacer(minLength: 0)
            if run.posted { ChatMessage(runs: run.sent) }
            if run.unfurled { GitHubPreview(arriving: run.arriving) }
        }
        .padding(.bottom, Chat.channelGap)
    }
}

/// What Slack puts under the message: the repository's own summary of the
/// pull request.
///
/// Indented to the message's text and not to its avatar, which is where Slack
/// puts an attachment and how it says which message it belongs to.
private struct GitHubPreview: View {
    /// 0 as it arrives, 1 once it is placed.
    let arriving: Double

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Parrot.leaf)
                .frame(width: Chat.s(3))
            VStack(alignment: .leading, spacing: Chat.s(3)) {
                HStack(spacing: Chat.s(5)) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: Chat.s(9), weight: .semibold))
                    Text(TutorialSlack.repo)
                        .font(.system(size: Chat.s(11)))
                }
                .foregroundStyle(Color.white.opacity(0.50))

                Text(TutorialSlack.request)
                    .font(.system(size: Chat.s(13), weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.90))

                HStack(spacing: Chat.s(6)) {
                    Text("Open")
                        .font(.system(size: Chat.s(10), weight: .semibold))
                        .foregroundStyle(Parrot.leaf)
                        .padding(.horizontal, Chat.s(5))
                        .padding(.vertical, Chat.s(1))
                        .background(Parrot.leaf.opacity(0.18), in: Capsule())
                    Text(TutorialSlack.label)
                        .font(.system(size: Chat.s(11)))
                        .foregroundStyle(Color.white.opacity(0.50))
                }
            }
            .padding(.vertical, Chat.s(8))
            .padding(.leading, Chat.s(10))
            .padding(.trailing, Chat.s(12))
            Spacer(minLength: 0)
        }
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: Chat.s(8), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Chat.s(8), style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        }
        .padding(.leading, Chat.s(32))
        // Out from under the message, which is where it comes from.
        .offset(y: -Chat.s(6) * (1 - arriving))
        .opacity(arriving)
    }
}
