#!/usr/bin/env python3
"""A word or phrase said twice in a row, taken out. Transcript on stdin, rewrite
on stdout.

    - name: repetitions
      description: delete a word or phrase said twice by accident
      command: repetitions.py
      when: /\\b(\\w+(?:\\s+\\w+){0,3})\\s+\\1\\b/

Not `disfluency`, which asks a model to resolve what you meant ("with John, no,
with Mark") and is reached by voice. This one deletes only an exact copy of
what is already there, so it can run on every transcript — no model, no
network.

Must run after `fillers` (a filler between the copies hides the repeat, "It's
the uh the summary") and after `numbers` ("two two three" is 223, not 23 with
"two" collapsed first).

Timing is not used to tell a stutter from an intentional repeat — measured and
found not to separate them. See scripts/disfluency-signals.py.
"""
import re
import sys

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


def protected(tokens, i, n, text, words):
    """Is this repeat one the speaker meant?

    The repeat is `tokens[i:i+n]` followed by `tokens[i+n:i+2n]`. `words` holds
    the match objects, for the raw spelling and the text between the copies.
    """
    unit = tokens[i:i + n]

    if any(w in NEVER_COLLAPSE for w in unit):
        return True

    # A number read as digits — losing one is unrecoverable.
    if any(w.isdigit() for w in unit):
        return True

    if n > 1 and any(w in CONJUNCTIONS for w in unit):
        return True

    # A spelled name: doubled uppercase letter, starts with one, or the whole
    # unit is single letters.
    raw = [words[j].group() for j in range(i, i + n)]
    if any(is_letter(r) and r.isupper() for r in raw):
        return True
    if n > 1 and all(is_letter(r) for r in raw):
        return True
    # Lowercase single letter: only a spelling if it sits among other letters.
    if n == 1 and is_letter(raw[0]):
        before = words[i - 1].group() if i > 0 else ""
        after = words[i + 2 * n].group() if i + 2 * n < len(words) else ""
        if is_letter(before) or is_letter(after):
            return True

    if SENTENCE_END.search(text[words[i + n - 1].end():words[i + n].start()]):
        return True

    return False


# Single letters that are real words — deleting one as a false start breaks
# the sentence.
#   a, i    EN: "I imagine" -> "imagine"; "a answer" -> "answer"
#   a, à    FR: "il a acheté"
#   y       FR: "il y a"
#   o, ô    FR vocative
SINGLE_LETTER_WORDS = {"a", "i", "y", "à", "o", "ô"}


def drop_fragments(text):
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

        head = text[:words[edit].start()]
        tail = text[words[edit + 1].start():]
        if words[edit].group()[:1].isupper() and tail[:1].islower():
            tail = tail[:1].upper() + tail[1:]
        text = head + tail


def collapse(text):
    """Both passes, to a fixed point — a dropped fragment can expose a new
    repetition ("w we we can")."""
    while True:
        out = collapse_repeats(drop_fragments(text))
        if out == text:
            return out
        text = out


def collapse_repeats(text):
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
                if protected(tokens, i, n, text, words):
                    continue
                edit = (i, n)
                break
            if edit:
                break

        if not edit:
            return text

        i, n = edit
        # Whatever sits between the two copies goes with the cut.
        head, tail = text[:words[i].start()], text[words[i + n].start():]
        # Keep the deleted copy's case: "The the prompt" -> "The prompt".
        if words[i].group()[:1].isupper() and tail[:1].islower():
            tail = tail[:1].upper() + tail[1:]
        text = head + tail


def main():
    text = sys.stdin.read()
    try:
        sys.stdout.write(collapse(text))
    except Exception:
        # Fail open — never drop the whole transcript because a guard threw.
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
