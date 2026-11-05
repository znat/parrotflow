#!/usr/bin/env python3
# parrotflow: {returns: json, parse: true, readings: true, runner: python}
"""Sentence marks a pause wrote, taken out again.

    - name: sentence_repair
      description: repair sentence boundaries a pause cut
      command: built-in/sentence_repair/sentence_repair.py

A pause makes the decoder write a sentence mark and a capital where the
speaker did not end a sentence. Three shapes, three rules:

    periods    "word. lowercase"   the period goes, unless the word before it
                                    is an abbreviation. No model: in 9,399
                                    clips this shape was never a sentence end.
    capitals   "word Capital"      a capital mid-sentence is lowercased,
                                    unless the parse says it is a name.
    joins      "word. Capital"     Qwen's readings decide. When `join` wins,
                                    the mark goes and the capital is re-cased
                                    by the capitals rule. A comma or a mark
                                    winning changes nothing.

`word? Capital` is a join like `word. Capital`. A doubled full stop `..` is
written as one, as the decoder meant.

A capital stays when any of these holds: the parse tags it PROPN; it is in a
named entity; it hangs off a capitalised PROPN at most two words away as
compound, amod, flat or nmod (Hugging Face, Red Cross); it is one letter,
unless a joined mark is before it and the parse calls it a function word (the
article "A"); it has a capital after its first letter (PR, iOS); it is "I" or starts with
"I'"; it is a nationality word in the dictated language; the `vocabulary`
stage wrote it.

No model is called here. The parse and the readings come in the envelope,
and every rule that needs one is skipped, and `declined` says so, when it is
missing. Score the cases with `score.py` beside this file.
"""
from __future__ import annotations

import difflib
import json
import os
import re
import sys
import unicodedata
from typing import TYPE_CHECKING, NamedTuple, Optional, cast

if TYPE_CHECKING:
    from typing import Callable, TypedDict

    from envelope import Ctx, Envelope, Parse, Readings, Reply, Scalar
    from typing_extensions import NotRequired

    class Facts(TypedDict):
        nationalities: frozenset[str]
        written: set[str]
        joined: NotRequired[bool]

# English capitalises these, French does not. A language with no row keeps no
# capital on this ground.
NATIONALITIES = {
    "en": frozenset({
        "african", "american", "arabic", "asian", "australian", "belgian",
        "brazilian", "british", "canadian", "catalan", "chinese", "dutch",
        "english", "european", "french", "german", "indian", "irish",
        "italian", "japanese", "korean", "mexican", "portuguese", "quebecois",
        "russian", "scottish", "spanish", "swiss",
    }),
    "fr": frozenset(),
}
NAME_PARTS = frozenset({"compound", "amod", "flat", "nmod"})
# A one-letter word of these classes after a joined mark is "A" or "À", not a
# spelled letter. Mid-sentence the parser tags spelled letters DET too.
FUNCTION_WORDS = frozenset({"DET", "ADP", "PRON", "CCONJ", "SCONJ", "AUX", "PART"})
# A capital after one of these, or after a line break, starts something.
OPENERS = re.compile(r"[.?!:;\"“”\n]")


class Word(NamedTuple):
    start: int
    end: int
    text: str
    upos: str
    head: Optional[int]
    deprel: str
    ner: Optional[str]


class Edit(NamedTuple):
    start: int
    end: int
    new: str
    rule: str


def characters(text: str) -> list[int]:
    """The code point each Swift Character of `text` starts at, and len(text).

    `at` in the envelope counts Characters, Python counts code points. A
    combining mark, a joiner and what it joins, a variation selector, a skin
    tone, the second half of a flag and the `\\n` of `\\r\\n` stay with the
    code point before them.
    """
    starts, previous, flag = [], "", False
    for at, char in enumerate(text):
        code = ord(char)
        regional = 0x1F1E6 <= code <= 0x1F1FF
        joined = (
            unicodedata.category(char) in ("Mn", "Me", "Mc")
            or char == "\u200d" or previous == "\u200d"
            or 0xFE00 <= code <= 0xFE0F or 0x1F3FB <= code <= 0x1F3FF
            or 0xE0020 <= code <= 0xE007F
            or (char == "\n" and previous == "\r")
            or (regional and flag)
        )
        if not joined:
            starts.append(at)
        flag = regional and not flag
        previous = char
    return starts + [len(text)]


def words_of(text: str, parse: Parse) -> list[Word] | None:
    """The parse's words, placed in `text` by their spelling, or None when the
    parse is of another text."""
    words, cursor = [], 0
    for word in parse["words"]:
        start = text.find(word["text"], cursor)
        if start < 0:
            return None
        cursor = start + len(word["text"])
        head = word["head"] - 1 if word["head"] else None
        words.append(Word(start, cursor, word["text"], word["upos"], head,
                          word["deprel"], word.get("ner")))
    return words


def written_by_vocabulary(vocabulary: dict[str, Scalar]) -> set[str]:
    """The words the `vocabulary` stage put in the text, lowercased."""
    tokens = re.compile(r"[\w'’-]+")
    found: set[str] = set()
    # A number here raises, and run() returns the text unrepaired.
    for term in (vocabulary.get("protected") or "").split("; "):  # type: ignore[union-attr]
        found.update(token.lower() for token in tokens.findall(term))
    before, judged = vocabulary.get("before"), vocabulary.get("judged")
    if isinstance(before, str) and isinstance(judged, str):
        a, b = tokens.findall(before), tokens.findall(judged)
        matcher = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
        for op, _, _, j1, j2 in matcher.get_opcodes():
            if op in ("replace", "insert"):
                found.update(token.lower() for token in b[j1:j2])
    return found


def in_a_name(i: int, words: list[Word]) -> bool:
    """Joined to a capitalised PROPN at most two words away by a name part,
    whichever of the two is the head: `flat` hangs Face off Hugging."""
    def joined(dependent: int, head: int) -> bool:
        return (words[dependent].head == head
                and words[dependent].deprel.split(":")[0] in NAME_PARTS
                and abs(dependent - head) <= 2)
    return any(
        words[j].upos == "PROPN" and words[j].text[:1].isupper()
        and (joined(i, j) or joined(j, i))
        for j in range(max(0, i - 2), min(len(words), i + 3)) if j != i)


# Why a capital stays, in the order the reason is reported.
GUARDS: tuple[tuple[str, Callable[[int, list[Word], Facts], bool]], ...] = (
    ("name", lambda i, words, facts: words[i].upos == "PROPN"),
    ("entity", lambda i, words, facts: bool(words[i].ner)),
    ("in a name", lambda i, words, facts: in_a_name(i, words)),
    ("letter", lambda i, words, facts: len(words[i].text) == 1 and not (
        facts.get("joined") and words[i].upos in FUNCTION_WORDS)),
    ("capitals", lambda i, words, facts: any(c.isupper() for c in words[i].text[1:])),
    ("I", lambda i, words, facts: words[i].text == "I" or words[i].text.startswith(("I'", "I’"))),
    ("nationality", lambda i, words, facts: words[i].text.lower() in facts["nationalities"]),
    ("term", lambda i, words, facts: words[i].text.lower() in facts["written"]),
)


def kept(i: int, words: list[Word], facts: Facts) -> str | None:
    """Why the capital of word `i` stays, or None if it goes."""
    return next((name for name, holds in GUARDS if holds(i, words, facts)), None)


def lowered(word: Word, rule: str) -> Edit:
    return Edit(word.start, word.start + 1, word.text[0].lower(), rule)


def periods(text: str, abbreviations: set[str]) -> list[Edit]:
    """`word. lowercase`: the period, or a doubled one, goes.

    The guards are `SentenceJoin.boundaries`'s: a mark in a run of three or more, a mark after
    a single letter or digit (J. smith, e.g. the) or after anything but a
    letter or a digit, and an abbreviation keep their period. So does a
    period before a line break.
    """
    edits = []
    for found in re.finditer(r"(?<![.\w])(\w+)(\.{1,2})(?!\.)([ \t]+)(?=\w)", text):
        word, after = found.group(1), text[found.end()]
        if len(word) < 2 or not word.isalnum() or word.lower() in abbreviations:
            continue
        if after.isalpha() and after.islower():
            edits.append(Edit(found.start(2), found.end(2), "", "period"))
    return edits


def joins(text: str, readings: Readings, words: list[Word], facts: Facts) -> list[Edit] | None:
    """Each boundary Qwen reads best with no mark: the mark goes, and with it
    the space French sets before `?`. The next word is re-cased by the
    capitals rule. A line break keeps its mark. None when the readings are not
    of this text."""
    at = characters(text)
    starts = {word.start: i for i, word in enumerate(words)}
    edits = []
    for boundary in readings.get("boundaries", []):
        if boundary.get("winner") != "join":
            continue
        if max(boundary["at"], boundary["word_at"]) >= len(at) - 1:
            return None
        mark, word = at[boundary["at"]], at[boundary["word_at"]]
        if text[mark] != boundary["mark"] or not text[word].isupper():
            return None
        if word not in starts or "\n" in text[mark:word]:
            continue
        end = mark + 1
        while end < word and text[end] == text[mark]:
            end += 1
        start = mark
        while start > 0 and text[start - 1].isspace():
            start -= 1
        edits.append(Edit(start, end, "", "join"))
        if not kept(starts[word], words, {**facts, "joined": True}):
            edits.append(lowered(words[starts[word]], "recased"))
    return edits


def capitals(text: str, words: list[Word], facts: Facts) -> list[Edit]:
    """A capital that follows no mark, lowercased unless a guard keeps it."""
    edits = []
    for i, word in enumerate(words):
        if i == 0 or not word.text[:1].isalpha() or not word.text[:1].isupper():
            continue
        previous = words[i - 1]
        if OPENERS.search(previous.text + text[previous.end:word.start]):
            continue
        if not kept(i, words, facts):
            edits.append(lowered(word, "capital"))
    return edits


def doubled(text: str) -> list[Edit]:
    """`..` written as `.`. Three or more is an ellipsis."""
    return [Edit(m.start() + 1, m.end(), "", "doubled")
            for m in re.finditer(r"(?<!\.)\.\.(?!\.)", text)]


def applied(text: str, edits: list[Edit]) -> tuple[str, list[Edit]]:
    """`text` with each edit made. An edit that overlaps an earlier one in the
    list is dropped."""
    taken: list[Edit] = []
    for edit in edits:
        if all(edit.end <= other.start or edit.start >= other.end for other in taken):
            taken.append(edit)
    for edit in sorted(taken, key=lambda e: e.start, reverse=True):
        text = text[:edit.start] + edit.new + text[edit.end:]
    return text, taken


def repair(text: str, envelope: Envelope) -> tuple[str, list[Edit], str]:
    """The repaired text, the edits made, and why a rule was skipped."""
    ctx = cast("Ctx", envelope.get("ctx") or {})
    variables = ctx.get("vars") or {}
    declined, edits = [], []
    lists = variables.get("lists") or {}
    if isinstance(lists.get("abbreviations"), str):
        abbreviations = {w.strip().lower() for w in cast("str", lists["abbreviations"]).split(";")}
        edits += periods(text, abbreviations)
    else:
        declined.append("periods: no abbreviation list")

    parse = envelope.get("parse")
    words = words_of(text, parse) if parse and parse.get("words") else None
    if words is None:
        declined.append("capitals and joins: no parse" if not parse else
                        "capitals and joins: the parse is of another text")
        return (*applied(text, edits + doubled(text)), "; ".join(declined))
    language = ctx.get("language") or cast("Parse", parse).get("language") or "en"
    facts: Facts = {
        "nationalities": NATIONALITIES.get(language, frozenset()),
        "written": written_by_vocabulary(variables.get("vocabulary") or {}),
    }
    readings = envelope.get("readings")
    if readings is None:
        declined.append("joins: no readings")
    elif readings.get("missing"):
        declined.append("joins: " + readings["missing"])
    else:
        found = joins(text, readings, words, facts)
        if found is None:
            declined.append("joins: the readings are of another text")
        else:
            edits += found
    edits += capitals(text, words, facts) + doubled(text)
    return (*applied(text, edits), "; ".join(declined))


def run(envelope: Envelope) -> Reply:
    text = envelope["text"]
    try:
        out, edits, declined = repair(text, envelope)
    except Exception as error:
        out, edits, declined = text, [], "failed: %s" % (str(error) or type(error).__name__)
    rules = [edit.rule for edit in edits]
    return {
        "text": out,
        "vars": {"count": rules.count("join"), "periods": rules.count("period"),
                 "capitals": rules.count("capital"),
                 "declined": declined},
    }


def main() -> int:
    structured = os.environ.get("PARROTFLOW_PROTOCOL") == "json"
    raw = sys.stdin.read()
    if structured:
        print(json.dumps(run(json.loads(raw))))
        return 0
    result = run({"text": raw, "ctx": {"vars": {}}, "tokens": [], "aligned": False})
    sys.stdout.write(cast("str", result["text"]))
    if result["vars"]["declined"]:
        sys.stderr.write(cast("str", result["vars"]["declined"]) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
