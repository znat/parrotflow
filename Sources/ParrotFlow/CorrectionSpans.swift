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
    /// Punctuation before the first word — an opening quote or bracket.
    var pre: String = ""
    var heard: [HeardWord]
    var value: [String]

    init(id: UUID = UUID(), pre: String = "", heard: [HeardWord], value: [String]) {
        self.id = id
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
    /// Nil means the end of the word.
    let at: Int?
}

final class SpansModel: ObservableObject {

    @Published var spans: [Span] = []
    /// Which word has the caret, and where to put it after a rebuild.
    @Published var focus: SpanCaret?
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

    private static let wordCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "'’-"))

    // MARK: - Loading

    func load(sentence: String) {
        spans = Self.read(sentence)
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

    static func read(_ sentence: String) -> [Span] {
        sentence.split(whereSeparator: \.isWhitespace).map { token in
            let text = String(token)
            var start = text.startIndex
            var end = text.endIndex
            while start < end, !isWord(text[start]) { start = text.index(after: start) }
            while end > start, !isWord(text[text.index(before: end)]) {
                end = text.index(before: end)
            }
            let word = String(text[start..<end])
            return Span(
                pre: String(text[text.startIndex..<start]),
                heard: [HeardWord(word: word, post: String(text[end...]))],
                value: [word]
            )
        }
    }

    private static func isWord(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { wordCharacters.contains($0) }
    }

    // MARK: - What comes out

    /// The caret starts in the first word. Without it the sentence reads as a
    /// label: the panel was tested and the one thing said about it was that it
    /// did not look editable.
    ///
    /// Called again once the panel is on screen. A field can only be made first
    /// responder through its window, and when the sentence loads there is no
    /// window yet.
    func focusFirst() {
        focus = spans.first.map { SpanCaret(span: $0.id, word: 0, at: nil) }
    }

    /// Anything to press the button for. Either a rule to teach, or a sentence
    /// that now reads differently — clearing a word teaches nothing, but it is
    /// still an edit, and dropping it into a dead button would lose it.
    var hasChanges: Bool { !rules().isEmpty || sentence() != original }

    /// One rule per span that changed. Keyed on the span, which is the point.
    func rules() -> [(heard: String, corrected: String)] {
        spans.filter(\.isChanged).compactMap { span in
            let heard = span.heardText
            let corrected = span.valueText
            guard !heard.isEmpty, !corrected.isEmpty else { return nil }
            return (heard, corrected)
        }
    }

    /// The sentence as it now reads, ready to go back where it came from.
    func sentence() -> String {
        spans.map { $0.pre + $0.valueText + $0.post }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
            focus = SpanCaret(span: id, word: word + parts.count - 1, at: nil)
            return
        }

        if text.isEmpty {
            remember()
            removeWord(span: id, word: word)
            return
        }

        rememberTyping(in: "\(id)-\(word)")
        spans[index].value[word] = text
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
            focus = SpanCaret(span: id, word: max(0, word - 1), at: nil)
            return
        }
        guard spans.count > 1 else { return }
        spans.remove(at: index)
        let back = max(0, index - 1)
        focus = SpanCaret(
            span: spans[back].id, word: spans[back].value.count - 1, at: nil
        )
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
            let seam = spans[index].value[word - 1].count
            spans[index].value[word - 1] += taken
            focus = SpanCaret(span: id, word: word - 1, at: seam)
            return
        }
        guard index > 0 else { past.removeLast(); return }

        let gone = spans.remove(at: index)
        var into = spans[index - 1]
        let last = into.value.count - 1
        let seam = into.value[last].count
        into.heard += gone.heard
        into.value[last] += gone.value.first ?? ""
        into.value += gone.value.dropFirst()
        spans[index - 1] = into
        focus = SpanCaret(span: into.id, word: last, at: seam)
    }

    // MARK: - Moving about

    /// The arrows keep their edge. From before the first character, left goes
    /// to before the first character of the word to the left; from after the
    /// last, right goes to after the last. At an edge you are moving between
    /// words rather than through them, and the caret should not change sides on
    /// the way.
    func step(from id: UUID, word: Int, forward: Bool, keepingEdge: Bool) {
        guard let target = neighbour(of: id, word: word, forward: forward) else { return }
        focus = SpanCaret(
            span: target.span, word: target.word,
            // Tab is a different job — arriving somewhere to change it — so it
            // lands on the last character whichever way it went.
            at: keepingEdge && forward ? nil : (keepingEdge ? 0 : nil)
        )
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

    private func rememberTyping(in where_: String) {
        let now = Date()
        if let typingAt, typingAt.word == where_,
           now.timeIntervalSince(typingAt.when) < 0.7 {
            self.typingAt = (where_, now)
            return
        }
        past.append(spans)
        if past.count > 60 { past.removeFirst() }
        typingAt = (where_, now)
    }

    var canUndo: Bool { !past.isEmpty }

    func undo() {
        guard let last = past.popLast() else { return }
        spans = last
        typingAt = nil
        focus = nil
    }
}
