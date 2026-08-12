#!/usr/bin/env python3
"""Spoken punctuation marks and quoted segments, English only. Transcript on
stdin, rewrite on stdout.

    - name: punctuation
      description: spoken marks as punctuation
      command: punctuation.py

"is that true question mark" -> "is that true?"

A spoken mark replaces whatever punctuation the decoder already guessed next
to it, on *either* side, rather than sitting beside it: "Yesterday, comma, I
was at a bar." -> "Yesterday, I was at a bar.", not "Yesterday,, I was at a
bar.". The decoder punctuates on pauses, and a pause is exactly what precedes
and follows a dictated mark — one on each side, in the common case.

No period rule — "period" and "full stop" are too ordinary ("a period of
time", "the bus makes a full stop", "I said no, full stop"). No rule beats a
wrong one; see docs/pipelines.md on `dotted` for the same call on "dot".

An article, conjunction or "around" right before the trigger ("a comma
splice", "around comma or exclamation point") means it's being talked about,
not dictated — declined. Kept deliberately short: most prepositions are also
how a phrasal verb ends ("hold on", "log in", "carry on"), so guarding on
"on"/"in" broke real instructions — measured, then rolled back. Known miss: a
modifier between the article and the noun ("the oxford comma") still slips
past. Thin evidence, not an archive — this hasn't been measured against real
dictation the way `dotted`'s guards were.
"""
import re
import sys

PUNCT = ".!?,:;"
# A word right before the trigger that means "the trigger is being talked
# about", not dictated as a mark.
NOT_A_MARK_AFTER = {"a", "an", "the", "and", "or", "nor", "around"}

MARK_BY_PHRASE = {
    "question mark": "?",
    "exclamation point": "!",
    "comma": ",",
    "colon": ":",
}
TRIGGER = re.compile(
    r"\s*\b(?:" + "|".join(re.escape(p) for p in
                            sorted(MARK_BY_PHRASE, key=len, reverse=True)) + r")\b",
    re.I)
WORD = re.compile(r"[\w']+")

QUOTE = re.compile(r"\bquote\s+(.+?)\s+unquote\b", re.I)


def marks(text):
    # Right to left, so an earlier rewrite cannot move a later match.
    for match in list(TRIGGER.finditer(text))[::-1]:
        mark = MARK_BY_PHRASE[match.group().strip().lower()]
        before, after = text[:match.start()], text[match.end():]
        if not before.strip():
            continue  # nothing to attach the mark to
        last_word = list(WORD.finditer(before))
        if last_word and last_word[-1].group().lower() in NOT_A_MARK_AFTER:
            continue  # trigger is being talked about, not dictated
        if before[-1:] in PUNCT:
            before = before[:-1]
        if after[:1] in PUNCT:
            after = after[1:]
        text = before + mark + after
    return text


def quotes(text):
    return QUOTE.sub(lambda m: f'"{m.group(1)}"', text)


def convert(text):
    return quotes(marks(text))


def main():
    text = sys.stdin.read()
    try:
        sys.stdout.write(convert(text))
    except Exception:
        # Fail open — never drop the whole transcript because a guard threw.
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
