#!/usr/bin/env python3
"""Spoken punctuation marks and quoted segments. Transcript on stdin, rewrite
on stdout.

    - name: punctuation
      description: spoken marks as punctuation
      command: punctuation.py
      returns: json

"is that true question mark" -> "is that true?"

**A language is a file.** `<lang>.yaml` beside this script holds the words and
the marks they write, and `ctx.language` picks it. No file for a language means
the stage does nothing and says so — `declined: no rules for de` — rather than
applying English rules nobody checked. The typography lives in the data too:
French `point d'exclamation` is `" !"` with a narrow no-break space, and
nothing here knows that.

`returns: json` is what sends the language and the word lists in. Without it
the script still runs and still rewrites, in English, with its own fallbacks —
which is what `echo "…" | ./punctuation.py` does.

A spoken mark replaces whatever punctuation the decoder already guessed next
to it, on *either* side, rather than sitting beside it: "Yesterday, comma, I
was at a bar." -> "Yesterday, I was at a bar.", not "Yesterday,, I was at a
bar.". The decoder punctuates on pauses, and a pause is exactly what precedes
and follows a dictated mark — one on each side, in the common case.

`quote … unquote` is the same rule and used not to be. You pause after saying
"quote", the decoder writes "quote, something unquote", and the comma it
guessed sat where the pattern needed a space — so the quotation was left as
the three words. The comma is now absorbed like any other guess.

**Quotations are read before marks.** That order is the only thing that tells
a guess from a dictation: before the mark pass runs, every punctuation
character in the transcript is the decoder's own; after it, some of them are
marks you asked for. "quote we ship today exclamation point unquote" keeps its
"!" because it is still the word "point" that sits before "unquote" when the
quotation is closed.

**What it writes, it publishes.** `protected` names the quoted segments, under
this stage's own name — the same contract `code_identifiers` uses for the
identifiers it builds. A quotation is verbatim by definition, so a later stage
that re-cases or deletes words reads that list and leaves it alone: "quote we
should ship this unquote" must not come out as "We should ship this" when "we"
is what was said.

The marks themselves are not in the list and do not need to be. Nothing
downstream rewrites a "?" or a ",". What downstream stages rewrite is words.

No period rule — "period" and "full stop" are too ordinary ("a period of
time", "the bus makes a full stop", "I said no, full stop"). No rule beats a
wrong one; see docs/pipelines.md on `dotted` for the same call on "dot".

An article, conjunction or "around" right before the trigger ("a comma
splice", "around comma or exclamation point") means it's being talked about,
not dictated — declined. Kept deliberately short: most prepositions are also
how a phrasal verb ends ("hold on", "log in", "carry on"), so guarding on
"on"/"in" broke real instructions — measured, then rolled back. A modifier
between the article and the noun ("the oxford comma") used to slip past; that
is now a word in `lists.talked_about` in config.yaml rather than a known miss,
and the same is true of whatever the next one turns out to be. Thin evidence,
not an archive — this hasn't been measured against real dictation the way
`dotted`'s guards were.
"""
import json
import pathlib
import re
import sys

import yaml

# What the decoder writes at a pause. A mark stands where its guess did.
PUNCT = ".!?,:;"
GUESSED = "[" + re.escape(PUNCT) + "]?"

# A word, for reading the one that sits before a trigger.
WORD = re.compile(r"[\w']+")

# A word right before the trigger that means "the trigger is being talked
# about", not dictated as a mark.
#
# The fallback, for a run with no config behind it — `echo | ./punctuation.py`,
# and the scorers. Otherwise this comes from `lists.talked_about` in
# config.yaml, where the same words are one definition rather than a copy per
# transform. See `read_list`.
NOT_A_MARK_AFTER = {"a", "an", "the", "and", "or", "nor", "around"}


def read_list(envelope, name, fallback):
    """A named word list from config.yaml, or the fallback.

    `lists.<name>` is published into the scope by the pipeline, joined on "; "
    because a scope value is a scalar. Adding a language is adding words there,
    and no transform has to be edited for it.
    """
    published = ((envelope or {}).get("ctx") or {}).get("vars") or {}
    raw = (published.get("lists") or {}).get(name)
    words = {w.strip().lower() for w in str(raw or "").split(";") if w.strip()}
    return words or fallback

def language_file(language):
    """The marks for a language, from `<lang>.yaml` beside this script.

    Nothing when there is no such file. Not a fallback to English: English
    rules on a language nobody checked fire words that mean something else,
    and silence about it is how that goes unnoticed. The stage says
    `declined: no rules for de` instead.

    `ctx.language` is what picks the file. A case states its own with `lang:`
    because detection is unreliable at the length a sentence is.
    """
    path = pathlib.Path(__file__).with_name(f"{(language or 'en').lower()}.yaml")
    if not path.exists():
        return None
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8")) or None
    except Exception:
        return None


def marks_of(table):
    """Phrase -> mark, and the trigger that finds them.

    Longest phrase first: "semi colon" must be tried before "colon", and
    "point d'interrogation" before "point-virgule".
    """
    by_phrase = {k.lower(): v for k, v in (table.get("marks") or {}).items()}
    if not by_phrase:
        return {}, None
    trigger = re.compile(
        r"\s*\b(?:" + "|".join(re.escape(p) for p in
                              sorted(by_phrase, key=len, reverse=True)) + r")\b", re.I)
    return by_phrase, trigger


def tight(phrase):
    """A pair phrase as a lookup key: lower case, no spaces."""
    return re.sub(r"\s+", "", phrase.lower())


def pairs_of(table):
    """Opening phrase -> (closing phrase -> mark pair), and the regex.

    A regular pair is the language's open/close verb, an optional determiner —
    "ouvrez LES parenthèses" — and the noun. An entry with its own `open:`/
    `close:` skips the verbs, which is how "quote … unquote" stops being a
    special case in code and becomes one entry of data.
    """
    spec = table.get("pairs") or {}
    opens, closes = spec.get("open") or [], spec.get("close") or []
    between = spec.get("between") or []
    by_open, phrases = {}, []
    for entry in spec.get("marks") or []:
        left, right = entry["mark"]
        own_open, own_close = entry.get("open"), entry.get("close")
        names = entry.get("names") or []
        starts = own_open or [f"{verb} {name}" for verb in opens for name in names]
        ends = own_close or [f"{verb} {name}" for verb in closes for name in names]
        if between and not own_open:
            starts += [f"{verb} {word} {name}"
                       for verb in opens for word in between for name in names]
            ends += [f"{verb} {word} {name}"
                     for verb in closes for word in between for name in names]
        # Keyed with the spaces taken out, because the pattern allows the
        # decoder's glued spelling and "openParen" has to find "open paren".
        for start in starts:
            by_open[tight(start)] = {tight(end): (left, right) for end in ends}
        phrases += starts + ends
    if not phrases:
        return {}, None
    # `\s*` where the phrase has a space, because the decoder writes "openParen"
    # as one word — it glues and camel-cases a pair it thinks it recognises.
    # `re.escape` leaves a space alone since 3.7, so this substitutes on the
    # space itself rather than on an escaped one.
    def loose(phrase):
        # `re.escape` escapes the space in this Python and leaves it alone in
        # others, so both spellings are substituted rather than one guessed at.
        return re.escape(phrase).replace("\\ ", r"\s*").replace(" ", r"\s*")

    alternation = "|".join(loose(p)
                           for p in sorted(set(phrases), key=len, reverse=True))
    pattern = re.compile(
        r"\b(" + alternation + r")\b" + GUESSED + r"\s+(.+?)" + GUESSED
        + r"\s+(" + alternation + r")\b", re.I)
    return by_open, pattern


class Heard:
    """One place a punctuation word was heard, asked in words rather than in
    offsets.

    Every question a guard needs is a property, so a guard reads as the
    sentence it is — `h.opens_the_utterance`, not `not text[:m.start()].strip()`.
    """

    __slots__ = ("text", "match", "not_a_mark_after", "by_phrase")

    def __init__(self, text, match, not_a_mark_after, by_phrase):
        self.text, self.match = text, match
        self.not_a_mark_after = not_a_mark_after
        self.by_phrase = by_phrase

    @property
    def phrase(self):
        return self.match.group().strip().lower()

    @property
    def mark(self):
        return self.by_phrase[self.phrase]

    @property
    def before(self):
        return self.text[:self.match.start()]

    @property
    def after(self):
        return self.text[self.match.end():]

    @property
    def opens_the_utterance(self):
        """Nothing said before it, so there is nothing to attach a mark to."""
        return not self.before.strip()

    @property
    def preceding_word(self):
        words = WORD.findall(self.before)
        return words[-1].lower() if words else ""

    @property
    def absorbed(self):
        """The two sides, with the decoder's own punctuation taken out.

        Both sides in the common case: a pause before the spoken mark and a
        pause after it, one guess written for each.
        """
        before, after = self.before, self.after
        if before and before[-1] in PUNCT:
            before = before[:-1]
        if after and after[0] in PUNCT:
            after = after[1:]
        return before, after


class Guard:
    """A reason to leave a trigger as the word it is, as a thing with a name.

    Every trigger here is an ordinary English word, so this stage declines far
    more often than it fires — and "why is my comma still a comma" is the
    question it generates. A guard that says its own name answers it in the
    trace instead of by reading the file.
    """

    __slots__ = ("name", "holds")

    def __init__(self, name, holds):
        self.name, self.holds = name, holds


# First match wins; the order is only which reason gets reported when both hold.
DECLINED = (
    Guard("nothing to attach it to", lambda h: h.opens_the_utterance),
    Guard("talked about, not dictated",
          lambda h: h.preceding_word in h.not_a_mark_after),
)


def declining(heard):
    """The name of the guard that holds this trigger, or None."""
    return next((g.name for g in DECLINED if g.holds(heard)), None)


def marks(text, by_phrase, trigger, applied=None, declined=None,
          not_a_mark_after=NOT_A_MARK_AFTER):
    if trigger is None:
        return text
    # Right to left, so an earlier rewrite cannot move a later match.
    for match in list(trigger.finditer(text))[::-1]:
        heard = Heard(text, match, not_a_mark_after, by_phrase)
        holds = declining(heard)
        if holds:
            if declined is not None:
                declined.append(f"{heard.phrase}: {holds}")
            continue
        before, after = heard.absorbed
        if applied is not None:
            applied.append(heard.phrase)
        text = before + heard.mark + after
    return text


def paired(text, by_open, pattern, applied=None, segments=None):
    """Every paired mark, including quotation. One pass, because in French
    "ouvrez les guillemets … fermez les guillemets" has the same shape as the
    parentheses — it is English that is irregular, and treating quotation as a
    special case was an English accident.
    """
    if pattern is None:
        return text

    def wrap(match):
        opening, body, closing = match.group(1), match.group(2), match.group(3)
        ends = by_open.get(tight(opening))
        if not ends:
            return match.group(0)
        # "open bracket … close parenthesis" names two different marks. One of
        # them is wrong and there is no way to tell which, so neither fires.
        found = ends.get(tight(closing))
        if not found:
            return match.group(0)
        left, right = found
        if applied is not None:
            applied.append(opening.lower())
        if segments is not None:
            segments.append(body)
        return left + body + right

    return pattern.sub(wrap, text)


def convert(text, language="en", applied=None, declined=None, written=None,
            not_a_mark_after=NOT_A_MARK_AFTER):
    """The rewrite, in whichever language the transcript is in.

    Paired marks first: they carry their own body, and a mark word inside one
    is part of what was quoted rather than a mark of its own.

    `written` collects the paired segments, which is what this stage publishes
    as `protected` — see `main`.
    """
    table = language_file(language)
    if table is None:
        if declined is not None:
            declined.append(f"no rules for {language}")
        return text
    by_phrase, trigger = marks_of(table)
    by_open, pattern = pairs_of(table)

    segments = []
    out = marks(paired(text, by_open, pattern, applied, segments),
                by_phrase, trigger, applied, declined, not_a_mark_after)
    if written is not None:
        # The segment as it reads *after* the mark pass, because a mark
        # dictated inside a pair is written by that pass: what a later stage is
        # handed is `we ship today!`, and "exclamation point" appears nowhere
        # in it.
        written.extend(marks(segment, by_phrase, trigger) for segment in segments)
    return out


def main():
    raw = sys.stdin.read()
    # Both protocols, decided by what arrives rather than by a flag. A bare
    # command gets its text back; a `returns: json` one gets the names of what
    # fired and what was declined as well, so the config key can be flipped
    # without the script changing.
    envelope = None
    try:
        candidate = json.loads(raw)
        if isinstance(candidate, dict) and isinstance(candidate.get("text"), str):
            envelope = candidate
    except (json.JSONDecodeError, TypeError):
        pass

    text = envelope["text"] if envelope else raw
    applied, declined, written = [], [], []
    try:
        # `determiners` as well: it is the same question `dotted` asks before a
        # name, and it is where the French words already live — "une virgule
        # sépare deux propositions" needs "une" and nothing else.
        out = convert(text, (envelope or {}).get("ctx", {}).get("language") or "en",
                      applied, declined, written,
                      read_list(envelope, "talked_about", NOT_A_MARK_AFTER)
                      | read_list(envelope, "determiners", set()))
    except Exception:
        # Fail open — never drop the whole transcript because a guard threw.
        out = text
    if envelope is None:
        sys.stdout.write(out)
        return
    print(json.dumps({
        "text": out,
        "vars": {
            # Deduplicated: three commas in one sentence name the mark once.
            "applied": ", ".join(dict.fromkeys(applied)),
            "declined": ", ".join(dict.fromkeys(declined)),
            "edits": len(applied),
            # The attribution a later stage reads — see the module docstring.
            # Joined on "; " because a scope value is a scalar, and the stage
            # that wrote them is the namespace they arrive under.
            "protected": "; ".join(dict.fromkeys(written)),
        },
    }))


if __name__ == "__main__":
    main()
