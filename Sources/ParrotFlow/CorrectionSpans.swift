import AppKit
import SwiftUI

/// The sentence you just said, as spans, so a rule can be keyed on one.
///
/// A span owns two lists — the words that were **heard** and the words that
/// **replace** them — and that is the whole idea. One heard word can become two
/// and two can become one without either side losing track of the other, which
/// is what a row-per-word panel could not express: `Redcrawl` decoded as "red
/// crawl" has no row to live on, and typing the name into the first row taught
/// the rule `red => Redcrawl`, which fires on the colour.
///
/// Everything below this panel already works in spans. The fuzzy pass scans
/// two-word windows, `Vocabulary.widerSpans` offers the wider span for a name
/// the decoder split, and `autoApplies` has a branch for exactly this shape.
/// The panel was the last place still counting in words.
struct HeardWord: Equatable {
    var word: String
    /// Punctuation that came after it. Kept per word so folding "his." into
    /// "praise" does not cost the sentence its full stop.
    var post: String = ""
}

struct Span: Identifiable, Equatable {
    let id: UUID
    /// The whitespace that came before this span in the text the panel opened
    /// on. Kept exactly, not normalised to one space: the panel opens on a
    /// selection as often as on a fresh dictation, and a tab, a double space or
    /// a line break in it is text nobody asked us to rewrite. The first span's
    /// lead is whatever the selection started with.
    ///
    /// Never drawn: `SentenceFlow` spaces the words itself. This is only what
    /// `sentence()` puts back.
    var lead: String = ""
    /// Punctuation before the first word — an opening quote or bracket.
    var pre: String = ""
    var heard: [HeardWord]
    var value: [String]
    /// This word holds punctuation that a join carried in, not punctuation
    /// anybody typed. Set by `joinBack`, cleared as soon as you type the word
    /// yourself, and it takes the span out of `rules()`.
    ///
    /// Provenance, not shape. Punctuation in a corrected word is often the
    /// whole point — `.NET`, `O'Reilly`, `C++` are the terms people come to
    /// this panel to teach — and no rule about which characters they are can
    /// tell those from a comma that arrived because ⌫ ate the space in
    /// "hello, world". Where the mark came from can.
    ///
    /// A flagged span still replaces. It teaches nothing, which is the right
    /// way to fail: a rule not learned costs one more correction next time, and
    /// a rule learned wrong fires forever, on sentences nobody meant to change.
    var joinedMarks = false

    init(
        id: UUID = UUID(), lead: String = "", pre: String = "",
        heard: [HeardWord], value: [String]
    ) {
        self.id = id
        self.lead = lead
        self.pre = pre
        self.heard = heard
        self.value = value
    }

    var heardText: String { heard.map(\.word).joined(separator: " ") }
    var heardShown: String { heard.map { $0.word + $0.post }.joined(separator: " ") }
    var valueText: String { value.joined(separator: " ").trimmingCharacters(in: .whitespaces) }
    var post: String { heard.last?.post ?? "" }
    var isChanged: Bool { valueText != heardText }
    /// Whether the struck line above the word has anything to say — the word
    /// changed, or more than one heard word became it.
    var showsHeard: Bool { isChanged || heard.count > 1 }
    /// More than one word on either side, so the underline has something to say
    /// by running under all of it.
    var isMulti: Bool { heard.count > 1 || value.count > 1 }
}

/// Where the caret is, so a structural edit can put it back.
struct SpanCaret: Equatable {
    let span: UUID
    let word: Int
    /// How far into the word, counted in **UTF-16 code units**. That is the one
    /// coordinate system in this file, and it is that one because AppKit's
    /// `NSRange` selection offsets are in it too, so `WordField` can use the
    /// number as it stands. `String.count` counts grapheme clusters instead:
    /// "😀" is 1 there and 2 here, "👩‍💻" is 1 there and 5 here, and a caret asked
    /// for the end of such a word would land short of it.
    ///
    /// Nil means the end of the word.
    let at: Int?
}

final class SpansModel: ObservableObject {

    @Published var spans: [Span] = []
    /// Which word has the caret, and where to put it after a rebuild.
    @Published var focus: SpanCaret?
    /// Bumped every time the focus is asked for, even when it lands on the word
    /// that already has it.
    ///
    /// `WordField` is driven by the value of `focus`, and an identical value is
    /// not a change: SwiftUI does not redraw, so `makeFirstResponder` never
    /// runs. That is exactly the opening focus — set once at load, asked for
    /// again once the panel has a window — so the counter is what makes the
    /// second ask a real one.
    ///
    /// It is also what re-arms a field you are coming back to. See `moveCaret`.
    @Published private(set) var focusTick = 0
    /// Held back until the first edit — before you have touched anything the
    /// panel has one job, and a row of keys under it is a manual for a thing
    /// you have not started doing.
    @Published var hasEdited = false
    /// The long explanation, open or shut. Shut on every appearance: it is a
    /// decision about the panel in front of you, not a preference to keep.
    @Published var help = false {
        didSet { onResize?() }
    }
    /// How wide the panel is. Fitted to the sentence when it loads, so a short
    /// one is not given a line break it does not need.
    @Published var width: CGFloat = CorrectionMetrics.minWidth

    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onResize: (() -> Void)?

    private var past: [[Span]] = []
    private var typingAt: (word: String, when: Date)?
    /// The sentence as it arrived, to tell "nothing has happened" from "one
    /// word was deleted". Neither teaches a rule; only one of them is a change
    /// worth a button.
    private var original = ""
    /// The whitespace after the last word of the selection. On the model rather
    /// than on a span: nothing can delete it, so nothing has to carry it.
    private var trailing = ""

    private static let wordCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "'’-"))

    // MARK: - Loading

    func load(sentence: String) {
        let read = Self.read(sentence)
        spans = read.spans
        trailing = read.trailing
        // Nothing readable: one empty span, so the panel opens with somewhere
        // to type rather than with no fields at all.
        if spans.isEmpty { spans = [Span(heard: [HeardWord(word: "")], value: [""])] }
        reset()
    }

    /// Spans built from the rules themselves, one span per rule.
    ///
    /// Not `load(sentence:)` over the heard words joined up: that splits on
    /// whitespace, so a rule that heard two words ("red crawl") becomes two
    /// spans, and every rule after it lands on the wrong one. A rule is already
    /// a span — heard words on one side, written words on the other — so it is
    /// carried across as one.
    func load(rules: [(heard: String, corrected: String)]) {
        spans = rules.compactMap { rule in
            let heard = rule.heard.split(whereSeparator: \.isWhitespace).map {
                HeardWord(word: String($0))
            }
            let value = rule.corrected.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !heard.isEmpty, !value.isEmpty else { return nil }
            return Span(heard: heard, value: value)
        }
        // No source text here, so there are no separators to carry: one space
        // between rules, which is what the panel assumed for everything before
        // the leads existed.
        for index in spans.indices.dropFirst() { spans[index].lead = " " }
        trailing = ""
        if spans.isEmpty { spans = [Span(heard: [HeardWord(word: "")], value: [""])] }
        reset()
    }

    private func reset() {
        past.removeAll()
        typingAt = nil
        hasEdited = false
        help = false
        original = sentence()
        focusFirst()
    }

    /// The sentence cut into spans, with the whitespace between them kept.
    ///
    /// Split-and-rejoin would be shorter and would normalise every separator to
    /// one space. The panel opens on selections, so that would rewrite a tab, a
    /// double space or a line break the user never touched, anywhere in the
    /// selection, because one word beside it was corrected. Each span carries
    /// the whitespace to its left; what is left over at the end is `trailing`.
    static func read(_ sentence: String) -> (spans: [Span], trailing: String) {
        var spans: [Span] = []
        var lead = ""
        var token = ""
        for character in sentence {
            if character.isWhitespace {
                if !token.isEmpty {
                    spans.append(span(token, lead: lead))
                    lead = ""
                    token = ""
                }
                lead.append(character)
            } else {
                token.append(character)
            }
        }
        // A word at the end takes the whitespace before it, so nothing trails.
        guard token.isEmpty else {
            spans.append(span(token, lead: lead))
            return (spans, "")
        }
        return (spans, lead)
    }

    /// One whitespace-free token, split into the punctuation around it and the
    /// word inside.
    private static func span(_ text: String, lead: String) -> Span {
        var start = text.startIndex
        var end = text.endIndex
        while start < end, !isWord(text[start]) { start = text.index(after: start) }
        while end > start, !isWord(text[text.index(before: end)]) {
            end = text.index(before: end)
        }
        let word = String(text[start..<end])
        return Span(
            lead: lead,
            pre: String(text[text.startIndex..<start]),
            heard: [HeardWord(word: word, post: String(text[end...]))],
            value: [word]
        )
    }

    private static func isWord(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { wordCharacters.contains($0) }
    }

    // MARK: - What comes out

    /// The caret starts before the first letter of the first word. Without it
    /// the sentence reads as a label: the panel was tested and the one thing
    /// said about it was that it did not look editable.
    ///
    /// `at: 0` rather than the end, which is what nil means everywhere else.
    /// Nil is right when you have arrived at a word to change it; here nothing
    /// has been chosen yet, and the caret sits at the start of the sentence the
    /// way it would in any other field you had just opened.
    ///
    /// Called again once the panel is on screen. A field can only be made first
    /// responder through its window, and when the sentence loads there is no
    /// window yet. See `focusTick` for what makes the second call count.
    func focusFirst() {
        moveCaret(to: spans.first.map { SpanCaret(span: $0.id, word: 0, at: 0) })
    }

    /// Put the caret somewhere, and renew the request so the field it names
    /// answers it.
    ///
    /// The renewal is the point. `WordField` clears its own `placeCaret` once a
    /// request has been answered, and arms it again only when the tick changes.
    /// So a field you have already visited has cleared it, and coming back —
    /// with an arrow, a tab, a join — would make it first responder and stop
    /// there. Making a text field first responder selects the whole of it, so
    /// the word would sit highlighted with the asked-for caret never placed,
    /// and the next character typed would replace the word.
    ///
    /// Every keyboard move goes through here. A click does not: AppKit has
    /// already put the caret where the pointer was, and re-placing it would
    /// drag it to the end of the word you clicked into.
    private func moveCaret(to caret: SpanCaret?) {
        focus = caret
        focusTick += 1
    }

    /// Anything to press the button for. Either a rule to teach, or a sentence
    /// that now reads differently — clearing a word teaches nothing, but it is
    /// still an edit, and dropping it into a dead button would lose it.
    var hasChanges: Bool { !rules().isEmpty || sentence() != original }

    /// One rule per span that changed. Keyed on the span, which is the point.
    ///
    /// Except a span whose punctuation a join carried in. That mark was never a
    /// decision about a word, and a rule holding it would put it back into
    /// every sentence that says those words again. See `Span.joinedMarks`.
    func rules() -> [(heard: String, corrected: String)] {
        spans.filter(\.isChanged).compactMap { span in
            guard !span.joinedMarks else { return nil }
            let heard = span.heardText
            let corrected = span.valueText
            guard !heard.isEmpty, !corrected.isEmpty else { return nil }
            return (heard, corrected)
        }
    }

    /// The sentence as it now reads, ready to go back where it came from.
    ///
    /// Concatenated, not joined with a space. Every span carries the whitespace
    /// that came before it, so the selection comes back spaced the way it went
    /// in — tabs, double spaces and line breaks included.
    func sentence() -> String {
        spans.reduce("") { $0 + $1.lead + $1.pre + $1.valueText + $1.post } + trailing
    }

    // MARK: - Editing

    /// A word was typed into. Coalesced, so a word typed letter by letter comes
    /// back in one undo rather than eight.
    func typed(_ text: String, span id: UUID, word: Int) {
        guard let index = spans.firstIndex(where: { $0.id == id }),
              spans[index].value.indices.contains(word) else { return }

        // Whitespace anywhere — typed, or pasted — splits. Two written words,
        // one heard span, and the underline runs under both to say so.
        if text.contains(where: \.isWhitespace) {
            let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
            remember()
            if parts.isEmpty {
                removeWord(span: id, word: word)
                return
            }
            spans[index].value.replaceSubrange(word...word, with: parts)
            spans[index].joinedMarks = false
            moveCaret(to: SpanCaret(span: id, word: word + parts.count - 1, at: nil))
            return
        }

        if text.isEmpty {
            remember()
            removeWord(span: id, word: word)
            return
        }

        rememberTyping(in: "\(id)-\(word)")
        spans[index].value[word] = text
        // Typed is intentional. Whatever a join left in this word, you have now
        // written the word yourself, so it is yours and it can be taught — even
        // when what you wrote has punctuation in it, which for a name like
        // "O'Reilly" is the reason you came to this panel.
        spans[index].joinedMarks = false
        hasEdited = true
    }

    /// A word cleared is a word you have decided not to write, and that is all
    /// it is. Nothing nests under the word before it, and nothing is taught — a
    /// rule mapping an ordinary word to nothing would fire on every dictation
    /// you ever gave. Joining two words is a separate gesture with its own key.
    private func removeWord(span id: UUID, word: Int) {
        guard let index = spans.firstIndex(where: { $0.id == id }) else { return }
        hasEdited = true
        if spans[index].value.count > 1 {
            spans[index].value.remove(at: word)
            moveCaret(to: SpanCaret(span: id, word: max(0, word - 1), at: nil))
            return
        }
        guard spans.count > 1 else { return }
        // The whitespace before a word belongs to that word, so it goes with
        // it: drop "bar" from "foo\nbar baz" and the line break goes too, and
        // the space before "baz" is the one that survives. The first span is
        // the exception — its lead is where the selection starts, not a gap
        // between two words — so it is handed to whatever takes its place.
        let gone = spans.remove(at: index)
        if index == 0 { spans[0].lead = gone.lead }
        let back = max(0, index - 1)
        moveCaret(to: SpanCaret(
            span: spans[back].id, word: spans[back].value.count - 1, at: nil
        ))
    }

    /// Backspace at the start of a word. Inside a span it glues two written
    /// words back together — the inverse of pressing space. At the head of a
    /// span it swallows the span before, heard and written both, and the caret
    /// sits at the seam.
    func joinBack(span id: UUID, word: Int) {
        guard let index = spans.firstIndex(where: { $0.id == id }) else { return }
        remember()
        hasEdited = true

        if word > 0 {
            let taken = spans[index].value.remove(at: word)
            // UTF-16, the unit `SpanCaret.at` is counted in.
            let seam = spans[index].value[word - 1].utf16.count
            spans[index].value[word - 1] += taken
            moveCaret(to: SpanCaret(span: id, word: word - 1, at: seam))
            return
        }
        guard index > 0 else { past.removeLast(); return }

        // The lead goes with the seam: the two words become one word, and one
        // word has no whitespace in the middle of it.
        let gone = spans.remove(at: index)
        var into = spans[index - 1]
        let last = into.value.count - 1
        // The punctuation that closed the word being joined to comes across
        // first. `sentence()` prints the last heard word's `post` and no other,
        // so once the two heard lists merge that mark has nowhere left to be
        // printed from: "hello, world" joined came back "helloworld", a comma
        // deleted by a keystroke aimed at the space.
        //
        // Read before the two heard lists merge, because after that `post` is
        // the swallowed span's own mark and no longer this one's.
        let swallowed = into.post
        into.value[last] += swallowed
        // Counted after it, so the caret lands where the space was rather than
        // in front of a mark that was already there.
        let seam = into.value[last].utf16.count
        into.heard += gone.heard
        // The punctuation that opened the swallowed span comes across too.
        // Without it "blue" and "(red" join to "bluered" — a bracket deleted by
        // a keystroke aimed at a space.
        into.value[last] += gone.pre + (gone.value.first ?? "")
        into.value += gone.value.dropFirst()
        // Both marks are in the word now, and neither was typed. The word still
        // goes back into the sentence — you joined it on purpose — but it
        // teaches nothing until you write it yourself. See `Span.joinedMarks`.
        if !(swallowed + gone.pre).isEmpty { into.joinedMarks = true }
        spans[index - 1] = into
        moveCaret(to: SpanCaret(span: into.id, word: last, at: seam))
    }

    // MARK: - Moving about

    /// The arrows keep their edge. From before the first character, left goes
    /// to before the first character of the word to the left; from after the
    /// last, right goes to after the last. At an edge you are moving between
    /// words rather than through them, and the caret should not change sides on
    /// the way.
    func step(from id: UUID, word: Int, forward: Bool, keepingEdge: Bool) {
        guard let target = neighbour(of: id, word: word, forward: forward) else { return }
        moveCaret(to: SpanCaret(
            span: target.span, word: target.word,
            // Tab is a different job — arriving somewhere to change it — so it
            // lands on the last character whichever way it went.
            at: keepingEdge && forward ? nil : (keepingEdge ? 0 : nil)
        ))
    }

    private func neighbour(
        of id: UUID, word: Int, forward: Bool
    ) -> (span: UUID, word: Int)? {
        guard let index = spans.firstIndex(where: { $0.id == id }) else { return nil }
        if forward {
            if word + 1 < spans[index].value.count { return (id, word + 1) }
            guard index + 1 < spans.count else { return nil }
            return (spans[index + 1].id, 0)
        }
        if word > 0 { return (id, word - 1) }
        guard index > 0 else { return nil }
        return (spans[index - 1].id, spans[index - 1].value.count - 1)
    }

    // MARK: - Undo

    private func remember() {
        past.append(spans)
        if past.count > 60 { past.removeFirst() }
        typingAt = nil
    }

    /// `field` names one word of one span, so typing on is coalesced and typing
    /// somewhere else is not.
    private func rememberTyping(in field: String) {
        let now = Date()
        if let typingAt, typingAt.word == field,
           now.timeIntervalSince(typingAt.when) < 0.7 {
            self.typingAt = (field, now)
            return
        }
        past.append(spans)
        if past.count > 60 { past.removeFirst() }
        typingAt = (field, now)
    }

    var canUndo: Bool { !past.isEmpty }

    func undo() {
        guard let last = past.popLast() else { return }
        spans = last
        typingAt = nil
        focus = nil
    }
}
