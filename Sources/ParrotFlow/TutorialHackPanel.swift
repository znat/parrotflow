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

    static let title = "Extensible"
    static let lead = "Customize dictation output with rules, prompts and scripts."

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

    /// Which of the two ways to reach a transform a line is about.
    ///
    /// The scripts card ends on both, one after the other: a key to press, then
    /// a thing to say. The lines for one are lit while that one is being made.
    enum Lit: Equatable {
        case key
        case say
    }

    /// One line of a config file, and whether it is one of the lines that does
    /// the work. The line that does is drawn bright and breathing; the rest is
    /// there so the line has somewhere to sit.
    struct Line: Equatable {
        let text: String
        /// The beat this line is lit on, or nil for a line that is only ever
        /// read as part of the file. `key: s` and the `S` on the chip are the
        /// same key, and the card says so by lighting all of one line and the
        /// keycap together.
        var lit: Lit?
        /// The line the card is about: the rule, the prompt, the script. It
        /// keeps its ink whatever else the card is stepping back from — it is
        /// the answer to what this kind of transform is, and a card that dims
        /// it to show a key off is dimming the thing it came to say.
        var works = false

        init(_ text: String, lit: Lit? = nil, works: Bool = false) {
            self.text = text
            self.lit = lit
            self.works = works
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
    static func spans(_ line: Line, lit: Lit?) -> [Span] {
        let out = syntax(line.text)
        guard let want = line.lit, want == lit else { return out }
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
                Line("  replace:", works: true),
                Line("    '[#$1](…/pull/$1)':", works: true),
                Line("      ['/\\bPR\\s*#?(\\d+)\\b/']", works: true),
            ]
        case .prompts:
            return [
                Line("# config.yaml"),
                Line("- name: grammar"),
                Line("  description: fix grammar and punctuation"),
                Line("  display: Fix grammar"),
                Line("  offer: true"),
                Line("  key: g"),
                Line("  prompt: |", works: true),
                Line("    Correct grammar and punctuation.", works: true),
            ]
        case .agent:
            // No config of its own: what this card shows is the asking.
            return []
        case .scripts:
            return [
                Line("# config.yaml"),
                Line("- name: slack_mentions"),
                Line("  description: names as slack mentions"),
                Line("  display: Slack mentions", lit: .key),
                Line("  offer: true"),
                Line("  key: s", lit: .key),
                Line("  say: [\(spoken)]", lit: .say),
                Line("  command: slack_mentions.py", works: true),
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
            return (
                "", "All you have to do is point your coding agent to the config.yaml",
                "", nil
            )
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
        OfferedCommand(title: "Slack mentions", key: "S"),
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

    /// After the scripts card has settled: how long before it steps back and
    /// the panel arrives in the room it made, how long the key is the only
    /// thing lit, and how long the finished card is held before the pass ends.
    ///
    /// The wait is long on purpose. What the card says next is that the key in
    /// the file is the key on the chip, and that is only read once the file has
    /// been read.
    static let step: TimeInterval = 3.5
    static let saying: TimeInterval = 3.4
    static let hold: TimeInterval = 3.0

    /// What the card says above the surface, on each of its two endings.
    static func ending(_ lit: Lit) -> String {
        switch lit {
        case .key: return "Add a custom key command"
        case .say: return "Or a vocal command"
        }
    }

    /// The command as it is said, which is also the `say:` value in the file.
    /// One spelling, so the words somebody hears cannot drift from the words
    /// the config matches.
    static let spoken = "add slack mention"
    static var spokenWords: [String] { spoken.split(separator: " ").map(String.init) }

    /// The say ending: how long the panel takes to give way to the pill, how
    /// long after that the first word lands, and how long a word takes.
    ///
    /// A key command can be shown by naming the key. A spoken one cannot: what
    /// there is to see is somebody holding the key and talking, so the panel
    /// goes and the pill that is up while the mic is open takes its place, with
    /// the words arriving beside it.
    static let handover: TimeInterval = 0.45
    static let beforeSpeaking: TimeInterval = 0.35
    static let perWord: TimeInterval = 0.5

    /// What the pill says it is listening about, which is what the app puts
    /// there: the words that are about to change, not a word for the gesture.
    /// See `AppDelegate.recordingLabel`.
    static var listening: String { outcome(.scripts).before }

    /// How long a card is up for. The scripts one gets longer than the rest: it
    /// ends on two things instead of one, and the second needs reading too.
    static func length(_ kind: Kind) -> TimeInterval {
        kind == .scripts ? between + saying + 1.0 : between
    }

    /// Where a card's own page begins, which is where the one before it ends.
    /// `arrives` is `first` later: the gap is the beat the card arrives on.
    static func startOf(_ kind: Kind) -> TimeInterval {
        Kind.allCases.prefix { $0 != kind }.reduce(0) { $0 + length($1) }
    }

    static func arrives(_ kind: Kind) -> TimeInterval { first + startOf(kind) }

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
        hasIcon: true, hotkey: Tutorial.hotkey, dock: .below
    )

    /// And the box the listening pill is laid out in, which is its own size:
    /// the words sit beside it, so there is no slack to centre it in.
    static let listeningBox: NSSize = PillMetrics.panelSize(
        for: .recording(listening),
        hasIcon: true, hotkey: Tutorial.hotkey, dock: .below
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
    /// 1 once the lit line is the only thing left to look at.
    var spotlight: Double {
        min(1, max(0, (t - taken) / 0.4))
    }

    /// Which of the card's two endings is up, or nil while the file is still
    /// being read whole.
    var lit: TutorialHack.Lit? {
        guard t >= taken else { return nil }
        return t >= said ? .say : .key
    }

    /// The moment the key ending gives way to the spoken one.
    private var said: TimeInterval { taken + TutorialHack.saying }

    /// How far the panel has given way to the listening pill: 0 on the key
    /// ending, 1 on the spoken one.
    var spoken: Double {
        min(1, max(0, (t - said) / TutorialHack.handover))
    }

    /// How many words of the command have been said.
    var spokenWords: Int {
        let into = t - said - TutorialHack.beforeSpeaking
        guard into > 0 else { return 0 }
        return min(
            TutorialHack.spokenWords.count,
            Int(into / TutorialHack.perWord) + 1
        )
    }

    /// What the meter is showing while the command is said.
    ///
    /// Two waves rather than one: a single sine reads as a metronome, and
    /// nothing anybody says moves a meter like that.
    var speechLevel: Double {
        let into = t - said
        guard into > 0 else { return 0 }
        return 0.18 + 0.34 * (0.5 + 0.5 * sin(into * 7.5))
            + 0.18 * (0.5 + 0.5 * sin(into * 3.1))
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

/// The screen the four config examples are drawn on.
///
/// It is a config file, and a config file is read at the reader's pace. The
/// pointer used to stop the pass wherever it was; the dots at the bottom of the
/// window do that job now, one a card, and they are the only thing on the tour
/// anybody can press. A hover that stopped the clock also stopped the dots
/// agreeing with the card, and it could hold a window with no buttons in it
/// open for as long as the pointer sat there.
struct TutorialHackPane: View {
    /// Seconds since this screen's demonstration started.
    let elapsed: TimeInterval
    /// The downloads, for the bar under the header.
    var progress: Double?
    var fetching: String?

    private var run: TutorialHackRun { TutorialHackRun(elapsed) }

    var body: some View {
        TutorialScreen(
            title: TutorialHack.title,
            lead: TutorialHack.lead,
            progress: progress,
            fetching: fetching
        ) {
            stage
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
                clicked: kind == .scripts ? run.clicked : nil,
                lit: kind == .scripts ? run.lit : nil,
                spoken: kind == .scripts ? run.spoken : 0,
                spokenWords: kind == .scripts ? run.spokenWords : 0,
                speechLevel: kind == .scripts ? run.speechLevel : 0
            )
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
    /// Which of the card's two endings is up, for the one card that has them.
    var lit: TutorialHack.Lit?
    /// How far the panel has given way to the listening pill, how many words of
    /// the command have been said, and what the meter is showing.
    var spoken: Double = 0
    var spokenWords: Int = 0
    var speechLevel: Double = 0

    var body: some View {
        // Stacked and not side by side: the config lines are the long thing on
        // the card, and the outcome beside them left the card too narrow for
        // either. A card is one column, and the result sits above the block
        // rather than inside it: it is what came out, not another line of the
        // file that produced it.
        VStack(alignment: .leading, spacing: 9) {
            // Full strength, and not faded with the rest: it says which of the
            // four this card is, which is the one thing on it that has to be
            // readable from across the room.
            Text(kind.label.uppercased())
                .font(.system(size: TutorialHack.labelSize, weight: .semibold, design: .rounded))
                .kerning(1.25)
                .foregroundStyle(Color.white.opacity(0.68))
            outcome.opacity(faded)
            if kind == .agent { terminal } else { block.padding(.top, 7) }
            if kind == .scripts {
                ending
                pill
            }
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
        }
    }

    /// What the lit line does, said above the panel it does it to.
    ///
    /// Always in the layout and only sometimes drawn, so the panel under it does
    /// not move on the frame this arrives.
    private var ending: some View {
        Text(TutorialHack.ending(lit ?? .key))
            .font(.system(size: TutorialHack.labelSize, weight: .medium))
            .foregroundStyle(Color(white: 0.88))
            .opacity(spotlight)
            .padding(.top, 3)
            .fixedSize(horizontal: false, vertical: true)
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
            ForEach(
                Array(TutorialHack.spans(line, lit: lit).enumerated()), id: \.offset
            ) { _, span in
                piece(span, works: line.works)
            }
        }
        .font(.system(size: TutorialHack.face, design: .monospaced))
    }

    /// One piece of one line. Broken out of the line because the colours and the
    /// glow together are more than the type checker will take in one expression.
    private func piece(_ span: TutorialHack.Span, works: Bool) -> some View {
        let keyed = span.tone == .keyed
        return Text(span.text)
            // The lines the panel is built from are the ones the card steps
            // back from, so they keep all of their ink: fading them with
            // everything else is what took the brightness out of them. The line
            // that does the work keeps its own colours, at full strength.
            .foregroundColor(
                keyed ? .white : span.tone.colour.opacity(works ? 1 : faded)
            )
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
        // The others are short enough to hold one line, and holding it is what
        // keeps the mark behind them the width of the words. The agent's line is
        // a sentence and has to be allowed to wrap.
        .fixedSize(horizontal: kind != .agent, vertical: true)
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

    /// What the card ends on: the panel for the key, and then the mic for the
    /// words.
    ///
    /// Crossfaded rather than swapped, and the panel is what the card is sized
    /// to: the listening pill's own box is 40 points taller on every side, for
    /// a bloom that is mostly transparent, and reserving that put an empty band
    /// under the card on the beat before.
    @ViewBuilder private var pill: some View {
        if panel > 0 {
            offerPanel
                .opacity(1 - spoken)
                .overlay(alignment: .topLeading) { saying.opacity(spoken) }
        }
    }

    /// The post-dictation panel: the two transforms that asked for a chip, and
    /// the key each one was given in the config beside it.
    private var offerPanel: some View {
        TourPill(
            state: .offer(
                TutorialHack.chips, nil, Confidence.Reading(), open: true
            ),
            level: 0.18, clicked: clicked, landing: panel,
            reserved: TutorialHack.reserved
        )
    }

    /// The same command reached by saying it: the pill that is up while the mic
    /// is open, and the words arriving beside it one at a time.
    private var saying: some View {
        // The words about to change, which is what the app writes on a pill
        // that is routing rather than dictating.
        let state = PillState.recording(TutorialHack.listening)
        // A listening pill carries 52 points of transparent margin for its
        // bloom to fade out in, on every side. Centred against the box is
        // therefore centred against the pill, and the words are pulled back
        // across the margin to sit beside the pill rather than beside the
        // bloom.
        let bleed = PillMetrics.bleed(for: state)
        return HStack(alignment: .center, spacing: 0) {
            TourPill(
                state: state, level: speechLevel, clicked: nil,
                reserved: TutorialHack.listeningBox
            )
            words.padding(.leading, 14 - bleed)
        }
        // And the row itself back by the difference between the two margins, in
        // both directions, so the drawn pill starts exactly where the drawn
        // panel did. Without it the surface steps 40 points down and to the
        // right in the middle of the crossfade.
        .offset(
            x: -(bleed - PillMetrics.dockBleed),
            y: -(bleed - PillMetrics.dockBleed)
        )
    }

    /// The command, a word at a time.
    ///
    /// Every word is in the layout from the start and only its ink arrives, so
    /// the line does not grow to the right while it is being read. The closing
    /// quote waits for the last word: an empty gap before one reads as a line
    /// that failed rather than one still being said.
    private var words: some View {
        HStack(spacing: 0) {
            quote("“", showing: spokenWords > 0)
            ForEach(
                Array(TutorialHack.spokenWords.enumerated()), id: \.offset
            ) { at, word in
                Text(at == 0 ? word : " " + word)
                    .foregroundStyle(.white)
                    .opacity(at < spokenWords ? 1 : 0)
            }
            quote("”", showing: spokenWords == TutorialHack.spokenWords.count)
        }
        .font(.system(size: TutorialHack.outcomeSize, weight: .medium))
        .fixedSize()
    }

    private func quote(_ mark: String, showing: Bool) -> some View {
        Text(mark)
            .foregroundStyle(Color.white.opacity(0.45))
            .opacity(showing ? 1 : 0)
    }
}
