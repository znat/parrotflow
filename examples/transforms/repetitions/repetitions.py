#!/usr/bin/env python3
"""A word or phrase said twice in a row, taken out. Transcript on stdin, rewrite
on stdout.

    - name: repetitions
      description: delete a word or phrase said twice by accident
      command: repetitions.py
      when: /\\b(\\w+(?:\\s+\\w+){0,3})\\s+\\1\\b/

Add `returns: json` and it also publishes `repetitions.applied`, the names of
the passes that fired, and `repetitions.edits`, how many cuts they made.

Not `disfluency`, which asks a model to resolve what you meant ("with John, no,
with Mark") and is reached by voice. This one deletes only an exact copy of
what is already there, so it can run on every transcript — no model, no
network.

Must run after `fillers` (a filler between the copies hides the repeat, "It's
the uh the summary") and after `numbers` ("two two three" is 223, not 23 with
"two" collapsed first).

Timing is not used to tell a stutter from an intentional repeat. Measured over
281 clips and 9014 words: the first copy of a disfluent repeat is not drawled,
1.00x its own median against a claimed 1.50x, and intentional repeats score the
same. The cues that would separate them are F0 step-down and glottalisation,
and TDT exposes neither. So the stop list stays; there is nothing to replace it
with. Score the set with `score.py` beside this file.
"""
import json
import os
import re
import sys
from collections import namedtuple

# Longest repeated phrase considered; longer than 3 words is unseen in the archive.
MAX_PHRASE = 4

# A word: apostrophes/accents included ("what's", "très"); a dot is not, so
# "x.y" is two tokens.
WORD = re.compile(r"[\wÀ-ɏ'’-]+")

# Said twice on purpose — collapsing changes the meaning.
#   blah, dot            idiom / dictated ellipsis
#   yeah/oui/non/si/no   affirmation or denial, doubled is still one
#   that, had            "that that person said", "I had had enough"
#   very, très           emphasis is the second copy
#   vous, nous           French reflexive: "vous vous êtes" needs both
#   ha, la               laughter / singing
NEVER_COLLAPSE = {
    "blah", "dot", "yeah", "oui", "non", "si", "no",
    "that", "had", "very", "très", "tres", "vous", "nous", "ha", "la",
}

# Numbers as words — "numbers" doesn't recognise all forms ("twenty two two"),
# and collapsing a repeated digit-word changes the value.
NUMBER_WORDS = {
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
    "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
    "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
    "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
    "thousand", "million", "billion",
    "zéro", "un", "une", "deux", "trois", "quatre", "cinq", "sept", "huit",
    "neuf", "dix", "onze", "douze", "treize", "quatorze", "quinze", "seize",
    "vingt", "trente", "quarante", "cinquante", "soixante", "cent", "cents",
    "mille", "milliard",
}
NEVER_COLLAPSE |= NUMBER_WORDS

# A phrase with one of these is a list ("again and again"), not a stutter.
CONJUNCTIONS = {"and", "or", "et", "ou", "but", "mais", "nor", "ni"}

# Sentence boundary — two copies either side are two different sentences.
SENTENCE_END = re.compile(r"[.!?…]")


def bare(word):
    """The form two copies are compared on: no case."""
    return word.lower()


def is_letter(token):
    """A single letter, as in a name being spelled out."""
    return len(token) == 1 and token.isalpha()


class Repeat:
    """One candidate repetition: `tokens[i:i+n]` followed by `tokens[i+n:i+2n]`.

    `words` holds the match objects, so the raw spelling and the text between
    the copies stay reachable.
    """

    __slots__ = ("tokens", "i", "n", "text", "words")

    def __init__(self, tokens, i, n, text, words):
        self.tokens, self.i, self.n = tokens, i, n
        self.text, self.words = text, words

    @property
    def unit(self):
        """The repeated run, lowercased."""
        return self.tokens[self.i:self.i + self.n]

    @property
    def raw(self):
        """The same run as it is actually spelled."""
        return [self.words[j].group() for j in range(self.i, self.i + self.n)]

    @property
    def neighbours(self):
        """The words either side of the pair, for judging a lone letter."""
        before = self.words[self.i - 1].group() if self.i > 0 else ""
        after_at = self.i + 2 * self.n
        after = self.words[after_at].group() if after_at < len(self.words) else ""
        return before, after

    @property
    def between(self):
        """What sits between the two copies."""
        return self.text[self.words[self.i + self.n - 1].end():
                         self.words[self.i + self.n].start()]


# A reason to leave a repeat alone, with a name. `holds(repeat)` is the test.
Guard = namedtuple("Guard", ("name", "holds"))

# First match wins. The order only decides which name is reported when several
# guards hold. Every one of these was a real transcript the naive rule damaged.
KEPT = (
    Guard("meant twice", lambda r: any(w in NEVER_COLLAPSE for w in r.unit)),
    # A number read as digits — losing one is unrecoverable.
    Guard("a number", lambda r: any(w.isdigit() for w in r.unit)),
    Guard("a list", lambda r: r.n > 1 and any(w in CONJUNCTIONS for w in r.unit)),
    # A spelled name: one doubled capital letter, or a run that is all letters.
    # The capital-letter test is n == 1 only. Scanning a longer run with `any`
    # kept every English repeat holding "I" — "I mean I mean".
    Guard("spelled aloud",
          lambda r: (r.n == 1 and is_letter(r.raw[0]) and r.raw[0].isupper())
          or (r.n > 1 and all(is_letter(x) for x in r.raw))),
    # A lone lower-case letter is only a spelling if it sits among letters.
    Guard("a letter among letters",
          lambda r: r.n == 1 and is_letter(r.raw[0])
          and any(is_letter(x) for x in r.neighbours)),
    Guard("across a stop", lambda r: bool(SENTENCE_END.search(r.between))),
)


def protecting(tokens, i, n, text, words):
    """The name of the guard that holds this repeat, or None."""
    repeat = Repeat(tokens, i, n, text, words)
    return next((g.name for g in KEPT if g.holds(repeat)), None)


# Single letters that are real words — deleting one as a false start breaks
# the sentence.
#   a, i    EN: "I imagine" -> "imagine"; "a answer" -> "answer"
#   a, à    FR: "il a acheté"
#   y       FR: "il y a"
#   o, ô    FR vocative
SINGLE_LETTER_WORDS = {"a", "i", "y", "à", "o", "ô"}


def drop_fragments(text, applied):
    """A word begun, abandoned, and restarted: "I mean w we can try" -> "I
    mean we can try". Only the adjacent single-letter case; a longer fragment
    ("in the tr in the terminal") isn't reached. Thin evidence — 2 examples in
    the archive, one a counter-example — so this is tuned to miss rather than
    over-reach.
    """
    while True:
        words = list(WORD.finditer(text))
        edit = None

        for i in range(len(words) - 1):
            fragment, following = words[i].group(), words[i + 1].group()

            # Lowercase only — an uppercase letter is how this decoder writes
            # a letter being named or spelled.
            if len(fragment) != 1 or not fragment.isalpha() or not fragment.islower():
                continue
            if fragment in SINGLE_LETTER_WORDS:
                continue
            # The next word has to be the one that was begun.
            if len(following) < 2 or not following.lower().startswith(fragment):
                continue
            # A single letter among single letters is a spelling, not a stutter.
            before = words[i - 1].group() if i > 0 else ""
            after = words[i + 2].group() if i + 2 < len(words) else ""
            if is_letter(before) or is_letter(after):
                continue
            # "b. bananas" is a list label, not a false start.
            if SENTENCE_END.search(text[words[i].end():words[i + 1].start()]):
                continue

            edit = i
            break

        if edit is None:
            return text

        applied.append("false start")
        head = text[:words[edit].start()]
        tail = text[words[edit + 1].start():]
        if words[edit].group()[:1].isupper() and tail[:1].islower():
            tail = tail[:1].upper() + tail[1:]
        text = head + tail


def collapse(text, applied):
    """Both passes, to a fixed point — a dropped fragment can expose a new
    repetition ("w we we can").

    `applied` is the list each pass names itself into, once per cut.
    """
    while True:
        out = collapse_repeats(drop_fragments(text, applied), applied)
        if out == text:
            return out
        text = out


def collapse_repeats(text, applied):
    """Delete the earlier copy of each repetition; the last copy is kept (it
    carries the trailing punctuation/spacing). Longest phrase first, then
    restart — a short match collapsed first can hide a longer one.
    """
    while True:
        words = list(WORD.finditer(text))
        tokens = [bare(w.group()) for w in words]
        edit = None

        for n in range(MAX_PHRASE, 0, -1):
            for i in range(len(tokens) - 2 * n + 1):
                if tokens[i:i + n] != tokens[i + n:i + 2 * n]:
                    continue
                if protecting(tokens, i, n, text, words):
                    continue
                edit = (i, n)
                break
            if edit:
                break

        if not edit:
            return text

        i, n = edit
        applied.append("phrase said twice" if n > 1 else "word said twice")
        # Whatever sits between the two copies goes with the cut.
        head, tail = text[:words[i].start()], text[words[i + n].start():]
        # Keep the deleted copy's case: "The the prompt" -> "The prompt".
        if words[i].group()[:1].isupper() and tail[:1].islower():
            tail = tail[:1].upper() + tail[1:]
        text = head + tail


def main():
    # ParrotFlow sets PARROTFLOW_PROTOCOL=json when the transform declares
    # `returns: json`, so the config stays the only place the protocol is
    # named. Unset is the plain path, which is what the scorers pipe.
    structured = os.environ.get("PARROTFLOW_PROTOCOL") == "json"
    raw = sys.stdin.read()
    text = json.loads(raw)["text"] if structured else raw

    applied = []
    try:
        out = collapse(text, applied)
    except Exception:
        # Fail open — never drop the whole transcript because a guard threw.
        out = text
        applied.clear()

    if not structured:
        sys.stdout.write(out)
        return
    print(json.dumps({
        "text": out,
        # Deduplicated: three of the same fault name it once.
        "vars": {"applied": ", ".join(dict.fromkeys(applied)), "edits": len(applied)},
    }))


if __name__ == "__main__":
    main()
