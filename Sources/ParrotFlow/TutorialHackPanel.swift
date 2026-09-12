import AppKit
import SwiftUI

/// The third tour screen: the three kinds of transform, each written the way the
/// config file writes it and shown doing something to a dictation.
///
/// One screen and not three, because the point is that they are three ways of
/// saying the same thing: a name, a description, and one field that says what to
/// do with the words. A screen each would be three screens of config, and the
/// person watching would have to work out for themselves what they have in
/// common.
enum TutorialHack {

    static let title = "Hackable output"
    static let lead = "Transform your dictations with replacements, prompts and scripts."

    /// The three, in the order the screen shows them.
    enum Kind: Int, CaseIterable {
        /// The order is the walk's, not the config's: what a substitution is,
        /// then what the panel does with it, then what a prompt is, and last
        /// the agent that writes all of them.
        case replacements, scripts, prompts, agent

        var label: String {
            switch self {
            case .replacements: return "replacements"
            case .scripts: return "scripts"
            case .prompts: return "prompts"
            case .agent: return "coding agent"
            }
        }
    }

    /// The last card: the same thing again, asked for in words instead of
    /// written by hand. The agent is already reading `config.yaml` — it is the
    /// file this whole screen is about — so the fourth transform is a sentence
    /// to it.
    static let prompt = #"When I say "P zero or P one" I want "P0 or P1""#
    static let reply = "I'll add a transform to your config.yaml to format"
        + " priorities as you need them"
    static let status = "auto mode on"
    static let statusHint = "(shift+tab to cycle)"

    /// The terminal's own face. A step larger than the config's: there is less
    /// of it, and it is the last thing on the screen.
    static let terminalSize: CGFloat = 14

    /// How fast the request is typed, in characters a second. Quick: it is being
    /// typed by somebody who already knows what they are asking for, and the
    /// reading is the answer under it.
    static let typing: Double = 26

    /// How long that takes, end to end.
    static var typingTime: TimeInterval { Double(prompt.count) / typing }

    /// One line of a config file, and whether it is one of the lines that does
    /// the work. The line that does is drawn in the accent colour; the rest is
    /// there so the line has somewhere to sit.
    struct Line: Equatable {
        let text: String
        /// Drawn bright and breathing: the setting whose value is also on the
        /// chip. `key: s` and the `S` on *Slack handles* are the same key, and
        /// the card says so by lighting all of one line and the keycap.
        var bright = false

        init(_ text: String, bright: Bool = false) {
            self.text = text
            self.bright = bright
        }
    }

    /// What a piece of a line is, for the colours a YAML file is read in.
    enum Tone {
        /// The name of a setting.
        case key
        /// A quoted value.
        case string
        /// `true`, `false`, a number.
        case literal
        /// An unquoted value, and the body of a block scalar.
        case plain
        /// A line that says where this is written rather than what it does.
        case comment
        /// The dashes, colons and brackets that hold the lines together.
        case punctuation
        /// The letter that is also on the chip, which is drawn breathing.
        case keyed

        var colour: Color {
            switch self {
            case .key: return Parrot.action
            case .string: return Parrot.amber
            case .literal: return Parrot.leaf
            case .plain: return Color(white: 0.88)
            case .comment: return Color.white.opacity(0.38)
            case .punctuation: return Color.white.opacity(0.5)
            case .keyed: return .white
            }
        }
    }

    struct Span: Equatable {
        let text: String
        let tone: Tone

        init(_ text: String, _ tone: Tone) {
            self.text = text
            self.tone = tone
        }
    }

    /// One line, cut into the pieces its colours are drawn on.
    ///
    /// Not a parser. These are twelve known lines, and what this has to get
    /// right is which of them is a setting, which is a value, and which is the
    /// comment at the top — a tour that carried a real YAML parser would be
    /// showing the parser rather than the config.
    static func spans(_ line: Line) -> [Span] {
        let out = syntax(line.text)
        guard line.bright else { return out }
        // The line whose value is also on the chip is one colour, all of it:
        // picking the key out letter by letter made the reader find the letter
        // before they could see the line.
        return out.map { Span($0.text, .keyed) }
    }

    private static func syntax(_ text: String) -> [Span] {
        let indent = text.prefix { $0 == " " }
        var rest = Substring(text.dropFirst(indent.count))
        var out: [Span] = []
        if !indent.isEmpty { out.append(Span(String(indent), .punctuation)) }

        // A comment is the whole line, wherever it starts.
        if rest.hasPrefix("#") { return [Span(text, .comment)] }

        // A list item's dash.
        if rest.hasPrefix("- ") {
            out.append(Span("- ", .punctuation))
            rest = rest.dropFirst(2)
        }

        // A flow sequence: the one-string pattern of a `replace:` table.
        if rest.hasPrefix("[") {
            out.append(Span("[", .punctuation))
            let inner = rest.dropFirst().dropLast()
            if !inner.isEmpty { out.append(Span(String(inner), .string)) }
            out.append(Span("]", .punctuation))
            return out
        }

        // A line with no setting of its own: the body of a block scalar.
        guard let colon = rest.firstIndex(of: ":") else {
            out.append(Span(String(rest), .plain))
            return out
        }
        let name = String(rest[..<colon])
        out.append(Span(name, name.hasPrefix("'") ? .string : .key))
        out.append(Span(":", .punctuation))
        rest = rest[rest.index(after: colon)...]

        let spaces = rest.prefix { $0 == " " }
        if !spaces.isEmpty { out.append(Span(String(spaces), .punctuation)) }
        let value = rest.dropFirst(spaces.count)
        if value.isEmpty { return out }
        if value == "|" {
            out.append(Span("|", .punctuation))
            return out
        }
        if value == "true" || value == "false" {
            out.append(Span(String(value), .literal))
            return out
        }
        out.append(Span(String(value), value.hasPrefix("'") ? .string : .plain))
        return out
    }

    /// Each one as the config writes it, simplified. The real file has more
    /// lines; this screen is about which line matters.
    static func lines(_ kind: Kind) -> [Line] {
        switch kind {
        case .replacements:
            return [
                Line("# config.yaml"),
                Line("- name: github_refs"),
                Line("  description: PR numbers as links"),
                Line("  replace:"),
                Line("    '[#$1](…/pull/$1)':"),
                Line("      ['/\\bPR\\s*#?(\\d+)\\b/']"),
            ]
        case .prompts:
            return [
                Line("# config.yaml"),
                Line("- name: grammar"),
                Line("  description: fix grammar and punctuation"),
                Line("  display: Fix grammar"),
                Line("  offer: true"),
                Line("  key: g"),
                Line("  prompt: |"),
                Line("    Correct grammar and punctuation."),
            ]
        case .agent:
            // No config of its own: what this card shows is the asking.
            return []
        case .scripts:
            return [
                Line("# config.yaml"),
                Line("- name: slack_handles"),
                Line("  description: names as slack handles"),
                Line("  display: Slack handles", bright: true),
                Line("  say: [slack handles]"),
                Line("  offer: true"),
                Line("  key: s", bright: true),
                Line("  command: slack_handles.py"),
            ]
        }
    }

    /// What each one does to a dictation, when what it produces is words.
    ///
    /// The last one produces a panel instead, which is the thing that connects
    /// a `key:` in the config to a keycap on the pill.
    static func outcome(
        _ kind: Kind
    ) -> (before: String, after: String, note: String, link: String?) {
        switch kind {
        case .replacements:
            // Only the number is a link. The sentence around it is the sentence,
            // and colouring all of it said the whole line had become one.
            return (
                "Can you review the PR478", "Can you review the #478",
                "a link in Slack", "#478"
            )
        case .prompts:
            return ("i think its ready", "I think it’s ready.", "a model does it", nil)
        case .scripts:
            return ("Hey, Siobhan", "Hey @Sio", "", nil)
        case .agent:
            return ("", "Your coding agent does it for you", "", nil)
        }
    }

    /// The faces on a card, in one place because they are set against each other
    /// rather than against anything else on the screen.
    static let face: CGFloat = 15
    static let labelSize: CGFloat = 13.75
    static let outcomeSize: CGFloat = 17.5
    static let noteSize: CGFloat = 13.75

    /// The panel the last card puts up: the two transforms that asked for a
    /// chip, and the key each was given. Nothing else on the surface, because
    /// the panel is the thing being shown rather than the sentence above it.
    static let chips = [
        OfferedCommand(title: "Fix grammar", key: "G"),
        OfferedCommand(title: "Slack handles", key: "S"),
    ]

    /// The chip the pointer takes, which is the one the config gave a key to.
    static let chosen = 1

    // MARK: - The clock

    /// The screen shows **one transform at a time**: the config lines are what
    /// has to be read, and three of them at once is three things to read at
    /// once. Each card replaces the one before it on the same beat of the
    /// clock, so the eye is never asked to find the new one.
    ///
    /// When the first arrives, how long each one is up, how long a card takes to
    /// settle, how long after that its outcome is marked, and how long the mark
    /// takes to cross.
    static let first: TimeInterval = 0.25
    static let between: TimeInterval = 8.0
    static let placed: TimeInterval = 0.35
    static let after: TimeInterval = 0.6
    static let crossing: TimeInterval = 0.9

    /// How long after the request has been typed the agent's answer comes back,
    /// and how long it takes to arrive.
    static var answer: TimeInterval { typingTime + 0.45 }
    static let answerFade: TimeInterval = 0.5

    /// After the last card has settled: how long before it steps back and the
    /// panel arrives in the room it made, and how long the finished card is
    /// held before the pass ends.
    ///
    /// The wait is long on purpose. What the card says next is that the key in
    /// the file is the key on the chip, and that is only read once the file has
    /// been read.
    static let step: TimeInterval = 3.5
    static let hold: TimeInterval = 3.0

    /// The last line of the config the card is about, which is not in the file
    /// yet: the two transforms that asked for a chip are the two this one has,
    /// and the third is the reader's to write. Out of `lines` because it is
    /// hidden until the card steps back, and a line that is not shown does not
    /// belong to the file being shown.
    static let invitation = "# Add a custom command"

    static func arrives(_ kind: Kind) -> TimeInterval {
        first + Double(kind.rawValue) * between
    }

    static var last: Kind { .agent }

    /// One pass: each card, the room the panel needs on the third, and the
    /// agent's answer on the fourth.
    static var total: TimeInterval {
        arrives(.agent) + answer + answerFade + hold
    }

    /// The box the panel is laid out in. One state and one size: this screen
    /// shows the panel once, already open.
    static let reserved: NSSize = PillMetrics.panelSize(
        for: .offer(chips, nil, Confidence.Reading(), open: true),
        hasIcon: true, hotkey: "Right ⌥", dock: .below
    )
}

/// What the screen is doing at one moment, read off its own clock.
struct TutorialHackRun: Equatable {
    /// Seconds into one pass.
    let t: TimeInterval
    /// Seconds since this screen's demonstration started. The way on waits for
    /// it, and `t` wraps, so it cannot answer that.
    let elapsed: TimeInterval

    init(_ elapsed: TimeInterval) {
        self.elapsed = elapsed
        let total = TutorialHack.total
        guard total > 0 else { t = 0; return }
        let wrapped = elapsed.truncatingRemainder(dividingBy: total)
        t = wrapped < 0 ? wrapped + total : wrapped
    }

    /// Whether the demonstration has played once through. See
    /// `TutorialRun.finished`.
    var finished: Bool { elapsed >= TutorialHack.total }

    /// How far one card has arrived: 0 before it starts, 1 once it is placed.
    func arrival(_ kind: TutorialHack.Kind) -> Double {
        min(1, max(0, (t - TutorialHack.arrives(kind)) / TutorialHack.placed))
    }

    /// The mark behind that card's outcome: 0 before, 1 at its height, 0 after.
    ///
    /// A bell rather than a sweep. What the card has to say is that *this* is
    /// what the line above did, and a mark that arrives and leaves again says it
    /// without the eye having to follow anything across.
    func mark(_ kind: TutorialHack.Kind) -> Double {
        let at = TutorialHack.arrives(kind) + TutorialHack.after
        let u = (t - at) / TutorialHack.crossing
        guard u > 0, u < 1 else { return 0 }
        return sin(.pi * u)
    }

    /// The moment the last card steps back and the panel arrives in the room it
    /// made. One moment for the two of them, because what they say between them
    /// is that the key in the file and the key on the chip are one key.
    private var taken: TimeInterval {
        TutorialHack.arrives(.scripts) + TutorialHack.step
    }

    /// How much of the request has been typed, in characters.
    var typed: Int {
        let elapsed = t - TutorialHack.arrives(.agent)
        let count = Int((elapsed * TutorialHack.typing).rounded(.down))
        return min(TutorialHack.prompt.count, max(0, count))
    }

    /// How far the agent's answer has arrived, on the card that has one.
    var replied: Double {
        let from = TutorialHack.arrives(.agent) + TutorialHack.answer
        return min(1, max(0, (t - from) / TutorialHack.answerFade))
    }

    /// How far the rest of the card has stepped back: 0 while it is being read,
    /// 1 once the key is the only thing left to look at. The invitation under
    /// the panel arrives with it.
    var spotlight: Double {
        min(1, max(0, (t - taken) / 0.4))
    }

    /// Which card is on the screen, or nil before the first one arrives.
    var showing: TutorialHack.Kind? {
        TutorialHack.Kind.allCases.last { t >= TutorialHack.arrives($0) }
    }

    /// How far the panel has arrived. It arrives with the step back and not
    /// with the card: until the card has stepped back there is nowhere to put
    /// it, and a panel that has been sitting under the card all along is not
    /// what the card has just said.
    var panel: Double {
        min(1, max(0, (t - taken) / TutorialHack.placed))
    }

    /// Which chip the pointer is on, or nil while it is on none. Lit from the
    /// moment the panel arrives: the config named this chip, and one that was
    /// not lit would be saying the config named nothing.
    var clicked: Int? {
        t >= taken ? TutorialHack.chosen : nil
    }
}

/// The screen the three are drawn on.
///
/// The only screen of the three that can be interrupted. It is a config file,
/// and a config file is read at the reader's pace: the pointer stops the pass
/// where it is, and a dot takes it to any of the three and keeps it there. The
/// clock itself is never stopped — a tour that pauses by not running is a tour
/// that has to be restarted — so a pause is time taken off the clock instead.
struct TutorialHackPane: View {
    /// Seconds since this screen's demonstration started.
    let elapsed: TimeInterval
    /// Off for the offscreen sheet. See `PanelsCommand.tutorialSheet`.
    var showsFoot = true
    /// The downloads, for the bar under the header.
    var progress: Double?
    var onNext: () -> Void = {}
    var onBack: (() -> Void)?

    /// How much of the pass has been held back by every pause so far.
    @State private var held: TimeInterval = 0
    /// When the pause that is happening now began.
    @State private var since: Date?
    /// The pointer is on the screen.
    @State private var hovering = false

    private var paused: Bool { hovering }

    /// The moment this screen is showing.
    ///
    /// The clock, less everything a pause has taken off it — which while a pause
    /// is happening is a constant — and then folded into one card when a dot has
    /// been clicked. Folding rather than stopping: a card frozen at the moment
    /// it was clicked is a card frozen at the frame before it arrived, and the
    /// carousel looked broken because there was nothing on the screen to see.
    private var run: TutorialHackRun {
        let pause = since.map { Date().timeIntervalSince($0) } ?? 0
        return TutorialHackRun(elapsed - held - pause)
    }

    var body: some View {
        // No lead line: the title says what the screen is, and the three cards
        // are what it is about. A sentence over them was a fourth thing to read
        // first.
        TutorialScreen(
            title: TutorialHack.title,
            lead: "",
            showsFoot: showsFoot,
            onNext: onNext,
            onBack: onBack,
            showsLead: false,
            progress: progress
        ) {
            stage.onHover { inside in
                hovering = inside
                settle()
            }
        }
    }

    /// One card, and only ever one: it is replaced on the beat, which is the
    /// one thing on this screen that moves without being asked.
    @ViewBuilder private var stage: some View {
        if let kind = run.showing {
            TransformCard(
                kind: kind,
                arrival: run.arrival(kind),
                mark: run.mark(kind),
                spotlight: kind == .scripts ? run.spotlight : 0,
                replied: kind == .agent ? run.replied : 0,
                typed: kind == .agent ? run.typed : 0,
                panel: kind == .scripts ? run.panel : 0,
                clicked: kind == .scripts ? run.clicked : nil
            )
        }
    }

    /// Start or stop the clock, so that `held` and `since` between them always
    /// say how much of the pass has been held back.
    private func settle() {
        if paused, since == nil { since = Date() }
        if !paused, let began = since {
            held += Date().timeIntervalSince(began)
            since = nil
        }
    }

}

/// One kind of transform: what the config says on the left, and what the words
/// do on the right.
private struct TransformCard: View {
    let kind: TutorialHack.Kind
    /// How far the card has arrived, and how strong the mark on its outcome is.
    let arrival: Double
    let mark: Double
    /// How far everything but the key's line has stepped back.
    var spotlight: Double = 0
    /// How far the agent's answer has arrived, on the card that has one.
    var replied: Double = 0
    /// How much of the request has been typed.
    var typed: Int = 0
    /// How far the panel under it has arrived, for the one card that has one.
    var panel: Double = 0
    var clicked: Int?

    var body: some View {
        // Stacked and not side by side: the config lines are the long thing on
        // the card, and the outcome beside them left the card too narrow for
        // either. A card is one column, and the result sits above the block
        // rather than inside it: it is what came out, not another line of the
        // file that produced it.
        VStack(alignment: .leading, spacing: 9) {
            Text(kind.label.uppercased())
                .font(.system(size: TutorialHack.labelSize, weight: .semibold, design: .rounded))
                .kerning(1.25)
                .foregroundStyle(Color.white.opacity(0.45 * faded))
            outcome.opacity(faded)
            if kind == .agent { terminal } else { block.padding(.top, 7) }
            if kind == .scripts { pill }
        }
        // The card arrives from the left and settles. Nothing else on the screen
        // moves, so the three can be read while the next is arriving.
        .opacity(arrival)
        .offset(x: -10 * (1 - arrival))
    }

    /// The config block: the only thing on the card in a box.
    private var block: some View {
        config
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.white.opacity(0.05 * faded),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10 * faded), lineWidth: 1)
            }
    }

    private var config: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(TutorialHack.lines(kind).enumerated()), id: \.offset) { _, line in
                self.line(line)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // In the block, at the end, and in the same face as the rest of it:
            // it is a line of this file, and the one it has yet to have. Always
            // in the layout and only sometimes drawn, so that the panel under
            // the block does not move on the frame it arrives.
            if kind == .scripts {
                Text(TutorialHack.invitation)
                    .font(.system(size: TutorialHack.face, design: .monospaced))
                    .foregroundColor(.white)
                    .shadow(color: Color.white.opacity(0.35), radius: 3)
                    .opacity(spotlight)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// How much of the card's own ink is left. The line whose letter is on the
    /// chip keeps all of it: everything else is what it is stepping back from.
    private var faded: Double { 1 - 0.62 * spotlight }

    /// One line of the config, in the colours a YAML file is read in.
    ///
    /// An `HStack` of pieces rather than one `Text`, because the letter that is
    /// also on the chip has to breathe and a `Text` cannot carry an opacity into
    /// a concatenation. The face is monospaced, so the pieces meet exactly where
    /// one `Text` would have put them.
    private func line(_ line: TutorialHack.Line) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(TutorialHack.spans(line).enumerated()), id: \.offset) { _, span in
                piece(span)
            }
        }
        .font(.system(size: TutorialHack.face, design: .monospaced))
    }

    /// One piece of one line. Broken out of the line because the colours and the
    /// glow together are more than the type checker will take in one expression.
    private func piece(_ span: TutorialHack.Span) -> some View {
        let keyed = span.tone == .keyed
        return Text(span.text)
            // The lines the panel is built from are the ones the card steps
            // back from, so they keep all of their ink: fading them with
            // everything else is what took the brightness out of them.
            .foregroundColor(keyed ? .white : span.tone.colour.opacity(faded))
            .shadow(color: keyed ? Color.white.opacity(0.35) : .clear, radius: 3)
    }

    /// The words before and after, and what did it.
    private var outcome: some View {
        let it = TutorialHack.outcome(kind)
        return VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 1) {
                if !it.before.isEmpty {
                    Text(it.before)
                        .foregroundStyle(Color.white.opacity(0.42))
                }
                HStack(spacing: 7) {
                    if !it.before.isEmpty {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.35))
                    }
                    after(it)
                }
            }
            .font(.system(size: TutorialHack.outcomeSize, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Parrot.leaf.opacity(0.28 * mark))
            }
            .padding(.horizontal, -5)
            .padding(.vertical, -3)

            if !it.note.isEmpty {
                Text(it.note)
                    .font(.system(size: TutorialHack.noteSize))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
        }
        .fixedSize()
    }

    /// The terminal, for the card that has one: what was asked of the agent,
    /// and what it said it would do. A terminal because that is where the
    /// asking happens, and the file the agent has open is the same one this
    /// screen has been showing all along.
    private var terminal: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Text("❯").foregroundStyle(Color.white.opacity(0.85))
                // Typed, not placed: the request is the one thing on this
                // screen somebody did, and it arrives the way it arrived at the
                // terminal — a character at a time, with the block after it.
                Text(String(TutorialHack.prompt.prefix(typed)))
                    .foregroundStyle(Color(white: 0.93))
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle()
                    .fill(Color(red: 0.78, green: 0.60, blue: 0.88))
                    .frame(width: 7, height: TutorialHack.terminalSize)
            }
            HStack(alignment: .top, spacing: 7) {
                Text("⏺").foregroundStyle(Parrot.leaf)
                Text(TutorialHack.reply)
                    .foregroundStyle(Color(white: 0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(replied)
            HStack(spacing: 6) {
                Text("▶▶").foregroundStyle(Parrot.amber)
                Text(TutorialHack.status).foregroundStyle(Parrot.amber)
                Text(TutorialHack.statusHint)
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .font(.system(size: TutorialHack.terminalSize, design: .monospaced))
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.black.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    /// What the words became, with one part of them a link if that is what it
    /// became.
    @ViewBuilder private func after(
        _ it: (before: String, after: String, note: String, link: String?)
    ) -> some View {
        if let link = it.link, let at = it.after.range(of: link) {
            Text(it.after[..<at.lowerBound])
                + Text(link).foregroundColor(Chat.link)
                + Text(it.after[at.upperBound...])
        } else {
            Text(it.after).foregroundColor(.white)
        }
    }

    /// The post-dictation panel: the two transforms that asked for a chip, and
    /// the key each one was given in the config beside it.
    @ViewBuilder private var pill: some View {
        if panel > 0 {
            TourPill(
                state: .offer(
                    TutorialHack.chips, nil, Confidence.Reading(), open: true
                ),
                level: 0.18, clicked: clicked, landing: panel,
                reserved: TutorialHack.reserved
            )
        }
    }
}
