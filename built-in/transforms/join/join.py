#!/usr/bin/env python3
"""Fit a dictated sentence to the text it is landing in. Envelope on stdin.

    - name: join
      description: space and case the transcript to fit where the caret is
      command: join.py
      returns: json
      when: input.ok

Needs the `input` stage above it, which publishes what is either side of the
caret. Without that this is blind and returns the transcript untouched — which
is also what happens in a terminal, where the caret is not readable at all. See
docs/pipelines.md on Input.

Two decisions, taken from the two neighbours:

    before   whether to add a space, and whether the first letter is a capital
    after    whether to add a space, and whether a trailing full stop survives

The recogniser writes every clip as a standalone sentence — leading capital,
trailing stop — because it has never seen what surrounds it. That is right when
you are appending and wrong every other time. This is the stage that knows.

**Only a closed class of words has its capital lowered.** The first attempt
lowered anything the dictionary knew and turned "I called Sarah" into "I called
sarah" — `sarah` is in `data/common-words-en.txt`. Nothing in a capitalised word
says whether the capital is the decoder starting a clip or the speaker naming
somebody, so the open class is left alone. A stray capital mid-sentence is a
character you can see and delete; a lowercased name reads as correct.

That list is gone. The envelope carries `tokens`, tagged by `NLTagger` in the
app, and the first token's `tag` answers the question directly: `Verb` and
`Determiner` are lowered, `PersonalName` and `Noun` are not. "Postponed" is
fixed; "Sarah" and "Tasmeen" are safe.

**No tag, no lowering.** Run by hand, or by an app build older than `Tagger`,
this leaves every capital alone rather than falling back to a guess.
"""
import json
import re
import sys

# Ends a sentence. `…` included because the decoder writes it.
SENTENCE_END = ".!?…"
# After one of these a new sentence starts: space, then a capital.
OPENS_SENTENCE = re.compile(r"[" + re.escape(SENTENCE_END) + r"][\"'”’)\]]*\s*$")
# A clause boundary used to be its own rule. Writing the rules out showed it
# did exactly what the fallback does — space, then lower case — so there is one
# branch now. Kept as a note rather than a pattern: if a comma ever needs to
# differ from an ordinary word, this is where that starts.
# Nothing goes between these and what follows them.
GLUES = re.compile(r"[(\[{\"'“‘\-–—/@#]\s*$")
# A hyphen or a slash joins two halves of one word, and the second half of a
# word is not a name. "a well-Considered approach" has no reading where the
# capital is right, so this is the one place the open class is lowered too.
COMPOUND = re.compile(r"[\-–—/]$")

WORD = re.compile(r"[^\W\d_]+", re.UNICODE)

# Tags whose capital is always the decoder's, because the word is never a name.
# `Noun` is deliberately absent: "User", "Release" and "Tasmeen" all tag Noun,
# and so would any name the tagger does not recognise.
LOWERABLE_TAGS = {
    "Verb", "Adjective", "Adverb", "Number", "Determiner", "Pronoun",
    "Preposition", "Conjunction", "Particle", "Interjection",
}


def lowered(text, anything=False, tag=None):
    """The transcript with its first word lowercased, when that is safe.

    `anything` drops the closed-class guard, for the one position where no
    capital can be right — see `COMPOUND`.
    """
    match = WORD.search(text)
    if not match:
        return text
    first = match.group()
    # "I" is a word, and lowering it is wrong in every sentence in English.
    if first == "I":
        return text
    if first.isupper() and len(first) > 1:          # an acronym, not a capital
        return text
    # The tagger decides, and only the tagger. A closed list of function words
    # stood here first and was a second, weaker implementation of the same
    # question — the two disagreed on `half` and on `second`, which is what two
    # implementations of one decision always come to. With no tag there is no
    # evidence, and no evidence means the capital stays: a stray capital is a
    # character you can see, a lowercased name reads as correct.
    if not anything and tag not in LOWERABLE_TAGS:
        return text
    if first[:1].islower():
        return text
    return text[:match.start()] + first[0].lower() + text[match.start() + 1:]


def capitalised(text):
    match = WORD.search(text)
    if not match:
        return text
    first = match.group()
    if first[:1].isupper():
        return text
    return text[:match.start()] + first[0].upper() + text[match.start() + 1:]


# A stop that is not the end of a sentence. Case matters: the decoder writes a
# capital after a real boundary, so a lower-case word following one is the sign
# that the stop came from a pause rather than from a full stop.
SPURIOUS_STOP = re.compile(r"(?<=[^\W\d_])\.(\s+)([a-zà-öø-ÿ])")

# Written with a dot and followed by lower case on purpose.
ABBREVIATIONS = {
    "e.g", "i.e", "etc", "vs", "cf", "approx", "al", "ca", "dr", "mr", "mrs",
    "ms", "st", "no", "fig", "vol", "ed", "p", "pp", "resp", "env",
}


def unstopped(text, protected=None):
    """Stops the decoder wrote at a pause rather than at the end of a sentence.

    A boundary it means is followed by a capital, because it capitalises after
    one. A lower-case word after a stop is the decoder having heard a hesitation
    — "I think you should. try this" — and it is the highest-precision signal
    there is for that: measured over 369 mid-clip stops in one archive, 16 had a
    lower-case word after them and nearly all were wrong.

    Only the spaced shape. `should.try`, with no space, is indistinguishable
    from `join.py`, `package.json` and `Method.variable` — and measured over
    3,785 archived clips that second rule fired 24 times, of which 19 were real
    dotted names and at most 2 were stops worth removing. A word list of
    extensions held some of them and could never hold the rest: `work` and
    `example` and `variable` are ordinary words that happen to sit right of a
    dot. Deleted rather than tuned.

    What survives the deletion is a dot an earlier stage wrote, which is not a
    guess: `dotted` publishes `method.` and that is checked below.
    """
    fired = []

    def spaced(match):
        term, wrote = covering(text, match.start(), protected)
        if wrote:
            fired.append(f"{term} written by {wrote}")
            return match.group(0)
        words = text[:match.start()].split()
        head = words[-1].lower().strip(".,;:!?") if words else ""
        # A dot still inside the word is an abbreviation spelled with them —
        # "U.S.", "e.g." — and the stop after it is part of the spelling.
        if "." in head or head in ABBREVIATIONS:
            return match.group(0)
        fired.append("stop at a pause")
        return match.group(1) + match.group(2)

    return SPURIOUS_STOP.sub(spaced, text), list(dict.fromkeys(fired))


def protected_terms(envelope):
    """Terms an earlier stage wrote on purpose, by the stage that wrote them.

    The attribution is free. `ctx.vars` already nests by stage name, so a stage
    that publishes `protected` names itself by where the value lands —
    `{"code_identifiers": ["max_retries", "UserProfile"]}`. Joined on "; " on
    the way in because a scope value is a scalar.

    Nothing here knows about code_identifiers in particular. Any stage that
    writes a term it does not want undone publishes the same key.

    **Values, not offsets, and not by choice of encoding.** An offset published
    by an earlier stage is stale by the time this one runs: `dotted`, `numbers`
    and any prompt stage rewrite the text in between, and none of them can
    adjust somebody else's ranges. That is the same fact the envelope states as
    `aligned`, which is false as soon as any stage rewrites. A value survives a
    rewrite; a range does not.

    The cost is that two identical strings in one clip cannot be told apart, so
    a term a rule wrote protects an untouched twin as well. That errs on the
    safe side: over-protecting leaves a capital you can see and delete, while
    under-protecting turns `max_retries` into `Max_retries`.
    """
    found = {}
    for stage, published in ((envelope.get("ctx") or {}).get("vars") or {}).items():
        if not isinstance(published, dict):
            continue
        terms = [t for t in str(published.get("protected") or "").split("; ") if t]
        if terms:
            found[stage] = terms
    return found


def covering(text, index, protected):
    """The term covering `text[index]` and the stage that wrote it, or (None, None).

    By position, not by word: the question a stop asks is "did somebody put this
    exact character here on purpose", and the character sits inside a term
    rather than at the start of one. `dotted` publishes `method.` and the dot it
    wrote is that term's last character.
    """
    for stage, terms in (protected or {}).items():
        for term in terms:
            at = text.find(term)
            while at >= 0:
                if at <= index < at + len(term):
                    return term, stage
                at = text.find(term, at + 1)
    return None, None


def owner(head, protected):
    """The term at the start of `head` and the stage that wrote it, or (None, None).

    Matched against the text rather than against a token, because `WORD` here
    is letters only — it sees `max` in `max_retries`, which is the whole reason
    the identifier was being re-cased. Longest first, so `user_id` wins over a
    `user` some other stage claimed.
    """
    for stage, terms in (protected or {}).items():
        for term in sorted(terms, key=len, reverse=True):
            if head.startswith(term):
                return term, stage
    return None, None


class Neighbourhood:
    """What sits either side of the caret, asked in words rather than in regex.

    Every question a rule needs is a property here, so a rule reads as the
    sentence it is — `n.opens_sentence`, not `OPENS_SENTENCE.search(before)`.
    The patterns stay above; what moves is where they are consulted.

    `blind` is the terminal case and the `--pipeline` case: no caret was
    readable, so no question about the edges has an answer and the rules that
    ask must not fire.
    """

    def __init__(self, before, after):
        self.before = before
        self.after = after

    # --- what is known at all ---
    @property
    def blind(self):
        return self.before is None

    # --- the leading edge ---
    @property
    def line_start(self):
        """The caret is at the start of a line.

        Two ways to be: a newline behind, or a newline in front. The second is
        Slack — press shift-enter after "That's fantastic." and the box reports
        total 18, before 17, after "\n". The caret is given as 17, in front of
        the newline, while the text lands after it. The break is the separator
        either way, so nothing goes in front of it.
        """
        if self.blind:
            return False
        return (not self.before.strip()
                or self.before.endswith("\n")
                or (self.after is not None and self.after.startswith("\n")))

    @property
    def opens_sentence(self):
        return not self.blind and bool(OPENS_SENTENCE.search(self.before))

    @property
    def glued(self):
        """A bracket or a quote: what follows closes up against it."""
        return not self.blind and bool(GLUES.search(self.before))

    @property
    def after_compound(self):
        """A hyphen or a slash — the second half of one word, never a name."""
        return not self.blind and bool(COMPOUND.search(self.before.rstrip()))

    @property
    def spaced_already(self):
        return not self.blind and self.before.endswith((" ", "\t"))

    # --- the trailing edge ---
    @property
    def appending(self):
        """Nothing but whitespace follows, so the decoder's stop belongs."""
        return self.after is None or not self.after.strip()

    @property
    def rest(self):
        return "" if self.after is None else self.after.lstrip()

    @property
    def carries_on(self):
        """The sentence continues past the caret, so a stop of ours is wrong."""
        if self.appending:
            return False
        head = self.rest[:1]
        return head in SENTENCE_END + ",;:)]}\"'" or head.islower()

    @property
    def closes_up(self):
        """Something already occupies this position, so no space of ours."""
        if self.after is None or self.after == "":
            return False
        return self.after[:1] in " \t\n" or self.rest[:1] in SENTENCE_END + ",;:)]}"


class Rule:
    """One decision about the leading edge, as a thing with a name.

    A name is the point. The rules were an `elif` chain and it worked, but when
    a sentence came out wrong the only way to find out which branch did it was
    to read the file and guess — which is how three wrong diagnoses happened in
    one evening. A rule that can say its own name puts the answer in the trace:

        join   he asked → he asked   34ms
               applied="new sentence, stop at a pause"

    `space` is whether a separator is wanted, not whether one is written: an
    existing space is never doubled. `case` is `upper`, `lower`, `lower-any`
    (past the closed-class guard, for a compound) or `keep`.
    """

    __slots__ = ("name", "when", "space", "case")

    def __init__(self, name, when, space, case):
        self.name, self.when, self.space, self.case = name, when, space, case


# First match wins, so the order is the precedence. A line start beats
# everything, a compound hyphen beats the bracket it might sit inside, and
# "somewhere in a sentence" is what is left.
LEADING = (
    Rule("line start", lambda n: n.line_start, space=False, case="upper"),
    Rule("compound", lambda n: n.glued and n.after_compound,
         space=False, case="lower-any"),
    Rule("glued", lambda n: n.glued, space=False, case="lower"),
    Rule("new sentence", lambda n: n.opens_sentence, space=True, case="upper"),
    Rule("mid sentence", lambda n: True, space=True, case="lower"),
)


def one_sentence(text):
    """No sentence end except possibly the last character."""
    return not any(c in SENTENCE_END for c in text.rstrip()[:-1])


def join(text, before, after, tag=None, protected=None):
    """The fitted transcript, and the names of the rules that fitted it."""
    n = Neighbourhood(before, after)
    body, applied = unstopped(text.strip(), protected)
    if not body:
        return text, applied

    lead = ""
    if not n.blind:
        rule = next(r for r in LEADING if r.when(n))
        applied.append(rule.name)
        # An identifier an earlier stage wrote keeps the case that stage chose.
        # `max_retries` at a line start was becoming `Max_retries`, and no
        # amount of tagging fixes that: the word is a name because a stage made
        # it one, which is a fact about the pipeline and not about the language.
        first = WORD.search(body)
        term, wrote = owner(body[first.start():], protected) if first else (None, None)
        if wrote:
            applied.append(f"{term} written by {wrote}")
        elif rule.case == "upper":
            body = capitalised(body)
        elif rule.case == "lower":
            body = lowered(body, tag=tag)
        elif rule.case == "lower-any":
            body = lowered(body, anything=True, tag=tag)
        if rule.space and not n.spaced_already:
            lead = " "

    # The trailing edge. The decoder ends every clip with a stop because it
    # never saw what follows; landing inside a sentence, that stop is an
    # artefact. Not a `Rule`: these are two independent decisions rather than
    # one choice among several, and forcing them into first-match-wins would
    # describe them wrongly.
    tail = ""
    if not n.appending:
        if n.carries_on and body.endswith(".") and one_sentence(body):
            body = body[:-1]
            applied.append("clip stop dropped")
        tail = "" if n.closes_up else " "

    return lead + body + tail, applied


def main():
    raw = sys.stdin.read()
    try:
        envelope = json.loads(raw)
        text = envelope["text"]
    except (json.JSONDecodeError, KeyError, TypeError):
        # A bare command protocol, or something unreadable. Fail open: the
        # transcript is worth more than the formatting.
        sys.stdout.write(raw)
        return

    # One guard over the whole decision, not one over half of it. Every branch
    # below is formatting, and none of it is worth a lost transcript.
    try:
        tokens = envelope.get("tokens") or []
        tag = tokens[0].get("tag") if tokens else None
        box = ((envelope.get("ctx") or {}).get("vars") or {}).get("input") or {}
        before, after = box.get("before"), box.get("after")
        protected = protected_terms(envelope)
        if before is None and after is None:
            # No caret, so nothing can be decided about the edges. The stops
            # inside the sentence are a different question and need none, which
            # is what makes this worth running in a terminal.
            out, applied = unstopped(text, protected)
        else:
            out, applied = join(text, before, after, tag, protected)
    except Exception:
        out, applied = text, []
    print(json.dumps({"text": out, "vars": reported(applied)}))


def reported(applied):
    """The rules that fired, as one scalar.

    A comma-joined string rather than a list, because `Scope.Value` is
    `string | int | double | bool` — a `when:` condition compares scalars, and
    growing that type for one field is not worth it.
    """
    return {"applied": ", ".join(applied), "rules": len(applied)}


if __name__ == "__main__":
    main()
