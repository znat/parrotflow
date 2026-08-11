#!/usr/bin/env bash
# Checks the model behind the correction panel: the spans it reads a sentence
# into, and the sentence it gives back.
#
#   scripts/check-spans.sh
#
# Three things are worth a script rather than a look at the panel, because all
# three are invisible in it and all three were wrong once:
#
#   the whitespace     the panel opens on a selection as often as on a fresh
#                      dictation. A tab, a double space or a line break in it
#                      belongs to the user's text. Correcting one word must
#                      not reformat the rest
#   the punctuation    joining "blue" and "(red" with ⌫ has to keep the
#                      bracket, and joining "hello," and "world" has to keep
#                      the comma. ⌫ is aimed at the space, not at the marks
#                      either side of it
#   the caret offsets  `SpanCaret.at` counts UTF-16 code units, because that
#                      is what AppKit's selection ranges count. A character
#                      count agrees with it right up until a word holds an
#                      emoji or a combining accent
#
# `CorrectionSpans.swift` is compiled on its own against the driver below —
# there is no test target here, and the model needs no window, no microphone
# and no model to answer. The one symbol it reaches out of its file for is
# stubbed; if that list grows, this script says so by failing to compile.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Sources/ParrotFlow/CorrectionSpans.swift"

WORK="$(mktemp -d -t parrotflow-spans)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import AppKit

// The only symbol CorrectionSpans.swift reads from another file.
enum CorrectionMetrics { static let minWidth: CGFloat = 640 }

var checks = 0, failures = 0

func check(_ what: String, _ got: Any, _ want: Any) {
    checks += 1
    let got = show(got), want = show(want)
    if got == want {
        print("  ✓ \(what)  \(got)")
    } else {
        failures += 1
        print("  ✗ \(what)\n      got   \(got)\n      want  \(want)")
    }
}

/// Whitespace is the thing under test, so it has to be readable in the output.
func show(_ value: Any) -> String {
    String(describing: value)
        .replacingOccurrences(of: "\t", with: "\\t")
        .replacingOccurrences(of: "\n", with: "\\n")
}

func loaded(_ sentence: String) -> SpansModel {
    let model = SpansModel()
    model.load(sentence: sentence)
    return model
}

/// One word typed into, the way the field's delegate reports it.
func type(_ model: SpansModel, _ text: String, span: Int, word: Int = 0) {
    model.typed(text, span: model.spans[span].id, word: word)
}

func joinBack(_ model: SpansModel, span: Int, word: Int = 0) {
    model.joinBack(span: model.spans[span].id, word: word)
}

print("\n  --- the whitespace of the selection survives an edit ---")

for (name, sentence, want) in [
    ("a double space", "one  two", "one  TWO"),
    ("a tab", "one\ttwo", "one\tTWO"),
    ("a line break", "one\ntwo", "one\nTWO"),
    ("whitespace at both ends", "  one \t two\n", "  one \t TWO\n"),
] {
    let model = loaded(sentence)
    type(model, "TWO", span: 1)
    check(name, model.sentence(), want)
}

for sentence in ["a\n\nb\tc   d", "\n\thello\t\n", "   ", ""] {
    check("untouched: \(show(sentence))", loaded(sentence).sentence(), sentence)
}

do {
    let model = loaded("Hello,   \"world\"!")
    type(model, "World", span: 1)
    check("punctuation stays with its word", model.sentence(), "Hello,   \"World\"!")
}
do {
    // A word cleared takes the whitespace before it. That whitespace is where
    // the word sat; the separator that survives belongs to the word that stays.
    let model = loaded("foo\nbar baz")
    type(model, "", span: 1)
    check("a cleared word takes its own lead", model.sentence(), "foo baz")
}
do {
    // Except the first, whose lead is where the selection starts.
    let model = loaded("    foo bar")
    type(model, "", span: 0)
    check("the first word cleared leaves the indent", model.sentence(), "    bar")
}
do {
    let model = loaded("foo bar\n")
    type(model, "", span: 1)
    check("the last word cleared leaves the newline", model.sentence(), "foo\n")
}
do {
    let model = loaded("one\ttwosome")
    type(model, "two some", span: 1)
    check("a word split in two takes one space", model.sentence(), "one\ttwo some")
}
do {
    let model = loaded("red \t crawl")
    joinBack(model, span: 1)
    check("a join takes the whitespace at the seam", model.sentence(), "redcrawl")
}
do {
    let model = loaded("a  b  c")
    joinBack(model, span: 1)
    check("a join leaves the other separators", model.sentence(), "ab  c")
}
do {
    let model = loaded("foo\nbar baz")
    type(model, "", span: 1)
    model.undo()
    check("undo puts the whitespace back", model.sentence(), "foo\nbar baz")
}

print("\n  --- a join keeps the punctuation of what it swallowed ---")

do {
    let model = loaded("blue (red).")
    joinBack(model, span: 1)
    check("blue + (red", model.spans[0].value, ["blue(red"])
    check("blue + (red, and the full stop", model.sentence(), "blue(red).")
    // It used to teach `blue red => blue(red`, which put a bracket into every
    // later sentence that said those two words. A mark a join carried in was
    // never a decision about a word — see `Span.joinedMarks`.
    check("the rule it teaches", model.rules().map { "\($0.heard) => \($0.corrected)" },
          [String]())
    check("…because the mark was not typed", model.spans[0].joinedMarks, true)
}
do {
    let model = loaded("red crawl")
    joinBack(model, span: 1)
    check("nothing to carry", model.spans[0].value, ["redcrawl"])
}
do {
    // The other side of the seam. ⌫ at the start of a word is aimed at the
    // space before it, not at the comma before that.
    let model = loaded("hello, world")
    joinBack(model, span: 1)
    check("hello, + world", model.spans[0].value, ["hello,world"])
    check("…and the comma is still in the sentence", model.sentence(), "hello,world")
    check("…with the caret after it", model.focus?.at ?? -1, 6)
    // The comma is in the sentence and out of the rule. Both halves matter:
    // the user joined those words on purpose, and the mark they did not type
    // has no business in a correction that fires forever.
    check("…and the rule says nothing about it",
          model.rules().map { "\($0.heard) => \($0.corrected)" }, [String]())
}
do {
    // Both sides at once, and the sentence keeps every mark it arrived with.
    let model = loaded("say \"hello,\" (world).")
    joinBack(model, span: 2)
    check("both sides of the seam", model.sentence(), "say \"hello,\"(world).")
}

print("\n  --- the caret is counted in UTF-16, the unit AppKit ranges use ---")

// "e" and a combining acute: one character, two UTF-16 code units.
let accented = "caf\u{65}\u{301}"

// The two counts have to differ, or the checks below say nothing.
for (word, want) in [(accented, "4 5"), ("😀", "1 2"), ("👩‍💻", "1 5")] {
    check("characters against code units", "\(word.count) \((word as NSString).length)", want)
}

// The seam a ⌫ join leaves the caret on is the end of the word before it —
// exactly the number the two counts disagree about. Typed in rather than
// dictated, because `read` treats an emoji as punctuation around a word, so the
// only way one gets into a field is the keyboard.
for word in [accented, "😀", "👩‍💻", "abc"] {
    let model = loaded("x tail")
    type(model, word, span: 0)
    joinBack(model, span: 1)
    check("the seam after \(word)", model.focus?.at ?? -1, (word as NSString).length)
    check("…which is not its character count", model.focus?.at == word.count, word == "abc")
    check("…and the words are one", model.spans[0].value, [word + "tail"])
}
do {
    // The same seam inside one span: split a word, then join it back.
    let model = loaded("x")
    type(model, "\u{65}\u{301}😀 tail", span: 0)
    check("split into two words", model.spans[0].value, ["\u{65}\u{301}😀", "tail"])
    model.joinBack(span: model.spans[0].id, word: 1)
    check("the seam inside a span", model.focus?.at ?? -1,
          ("\u{65}\u{301}😀" as NSString).length)
}
do {
    // The panel opens with the caret before the first letter, whatever the
    // first word is made of.
    let model = loaded("\(accented) tail")
    check("the opening caret", model.focus?.at ?? -1, 0)
    check("…in the first word", model.focus?.word ?? -1, 0)
    check("…of the first span", model.focus?.span == model.spans[0].id, true)
}

print("\n  --- a mark a join carried in teaches nothing, and still replaces ---")

// Punctuation you typed is a decision about a word. Punctuation ⌫ dragged in
// off the sentence is debris from an edit. The model tells them apart by where
// the mark came from, not by which character it is — no shape rule can, because
// ".NET" and "O'Reilly" are exactly the terms this panel exists to teach.
do {
    let model = loaded("hello, world")
    joinBack(model, span: 1)
    check("the sentence still joins", model.sentence(), "hello,world")
    check("…and teaches nothing", model.rules().count, 0)
}
do {
    // The case the span model was built for. No punctuation, so nothing to
    // doubt: this one has to go on teaching.
    let model = loaded("red crawl")
    joinBack(model, span: 1)
    type(model, "Redcrawl", span: 0)
    check("a clean join still teaches",
          model.rules().map { "\($0.heard) => \($0.corrected)" },
          ["red crawl => Redcrawl"])
    check("…and was never flagged", model.spans[0].joinedMarks, false)
}
do {
    // Typed punctuation is intentional, wherever it lands.
    let model = loaded("dot net")
    type(model, ".NET", span: 0)
    check("punctuation you typed teaches",
          model.rules().map { "\($0.heard) => \($0.corrected)" }, ["dot => .NET"])
}
do {
    // Typed over a flagged word: it is your word now, punctuation and all.
    let model = loaded("O Reilly")
    joinBack(model, span: 1)
    type(model, "O'Reilly", span: 0)
    check("typing clears the flag", model.spans[0].joinedMarks, false)
    check("…so the name is taught",
          model.rules().map { "\($0.heard) => \($0.corrected)" },
          ["O Reilly => O'Reilly"])
}
do {
    // Undo carries the flag back with the spans, both ways round.
    let model = loaded("hello, world")
    type(model, "HELLO", span: 0)
    check("before the join it teaches",
          model.rules().map { "\($0.heard) => \($0.corrected)" }, ["hello => HELLO"])
    joinBack(model, span: 1)
    check("the join flags it", model.spans[0].joinedMarks, true)
    check("…and it teaches nothing", model.rules().count, 0)
    model.undo()
    check("undo puts the flag back down", model.spans[0].joinedMarks, false)
    check("…and the rule with it",
          model.rules().map { "\($0.heard) => \($0.corrected)" }, ["hello => HELLO"])
    check("…and the sentence", model.sentence(), "HELLO, world")
}
do {
    // A flagged span is still an edit, so the button is still live. Nothing to
    // teach is not nothing to do.
    let model = loaded("hello, world")
    joinBack(model, span: 1)
    check("nothing to teach is still something to save", model.hasChanges, true)
}

print("\n  --- every keyboard move is a new caret request ---")

// `WordField` arms itself off `focusTick`, and disarms once it has answered.
// A field you have already been in has disarmed, so a move back to it that did
// not renew the tick would leave the whole word selected and the next character
// typed would replace it.
do {
    let model = loaded("one two three")
    var tick = model.focusTick
    func moved(_ what: String) {
        check(what, model.focusTick > tick, true)
        tick = model.focusTick
    }
    model.step(from: model.spans[0].id, word: 0, forward: true, keepingEdge: true)
    moved("an arrow across an edge")
    model.step(from: model.spans[1].id, word: 0, forward: false, keepingEdge: true)
    moved("…and the arrow back to a word already visited")
    check("…which is the word it named", model.focus?.span == model.spans[0].id, true)
    model.step(from: model.spans[0].id, word: 0, forward: true, keepingEdge: false)
    moved("a tab")
    type(model, "two more", span: 1)
    moved("a word split in two")
    joinBack(model, span: 1, word: 1)
    moved("a join inside a span")
    joinBack(model, span: 1)
    moved("a join across spans")
    type(model, "", span: 1)
    moved("a word cleared")
    model.focusFirst()
    moved("the same word asked for twice")
}
do {
    // Nowhere to go is not a move. The tick has to stay put, or the field you
    // are in re-places the caret on the next redraw and typing drags it back.
    let model = loaded("one two")
    let tick = model.focusTick
    model.step(from: model.spans[0].id, word: 0, forward: false, keepingEdge: true)
    check("no neighbour, no new request", model.focusTick, tick)
}

print("\n  \(checks - failures)/\(checks)")
exit(failures == 0 ? 0 : 1)
SWIFT

swiftc -O -o "$WORK/spans" "$WORK/main.swift" "$SOURCE" || {
  echo "  the model no longer compiles on its own — see the note at the top"
  exit 1
}
"$WORK/spans"
