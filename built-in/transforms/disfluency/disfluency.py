#!/usr/bin/env python3
# parrotflow: {returns: json, parse: vectors}
"""What the speaker did not mean to say, taken out. Transcript on stdin,
rewrite on stdout.

    - name: disfluency
      description: delete hesitations, repeats and false starts
      command: disfluency.py

Four rules, in this order:

    repeats        an exact copy of what is already there — "the the prompt"
    fragments      a single letter begun and restarted — "w we can try"
    restarts       a phrase begun and begun again — "in the ter in the terminal"
    partials       a word begun and said in full — "co could you check"
    word fillers   a marker that carries nothing — "so use like you know five"

The first four are string work: no model, no network, and they run on every
transcript. The fifth needs a dependency parse, because "you know" is a real
verb with a real object half the time — "we'll let you know" must survive. It
reads the syrinx parse the app puts in the envelope (`parse: true`), and is
skipped, and says so, when the envelope has none.

With `parse: vectors`, the tree cutter runs after the rules. It reads the
parse's reparandum arcs as proposed cuts, and the cut filter V keeps one when
P(real) >= 0.75 and no rule already cut one of its words. Without vectors it is
skipped.

`returns: json` publishes `disfluency.applied`, the passes that fired, and
`disfluency.edits`, how many cuts they made. With the tree cutter,
`disfluency.tree_cuts` and `disfluency.tree_dropped`: proposals applied, and
dropped by V.

Hesitation sounds are NOT here. They have to run before the `numbers`
transforms — a filler inside a number splits it, "two uh two three" gives
"two uh 23" — and this stage has to run after them, or "two two three"
collapses to 23. They stay a `replace:` rule with a `lists:` entry, which
costs no process at all.

Timing is not used to tell a stutter from an intentional repeat. Measured over
281 clips and 9014 words: the first copy of a disfluent repeat is not drawled,
1.00x its own median against a claimed 1.50x, and intentional repeats score the
same. The cues that would separate them are F0 step-down and glottalisation,
and TDT exposes neither. So the stop list stays; there is nothing to replace it
with. Score the set with `score.py` beside this file.

No `when:`. A condition has to be a superset of everything the stage can act
on, and these five rules share no shape. An earlier backreference condition
silently stopped matching once the pass learned fragments.
"""
import base64
import json
import math
import os
import re
import struct
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

# A word begun and restarted is a content word. A function word before a longer
# word that starts with the same letters is almost always two ordinary words —
# "one on one", "we were", "an answer", "do does", "be better", "il a acheté".
#
# Measured over 8291 archive dictations: the bare prefix shape fires 142 times,
# this list takes it to 55, and about 52 of those are real restarts. A
# dictionary instead of this list keeps only 18 and loses the whole
# singular-to-plural class — "issue issues", "transcript transcripts".
FUNCTION_WORDS = {
    # EN determiners, pronouns, auxiliaries, prepositions, conjunctions
    "a", "an", "the", "this", "that", "these", "those", "my", "your", "his",
    "her", "its", "our", "their", "i", "you", "he", "she", "it", "we", "they",
    "me", "him", "them", "us", "am", "is", "are", "was", "were", "be", "been",
    "being", "do", "does", "did", "done", "have", "has", "had", "can", "could",
    "will", "would", "shall", "should", "may", "might", "must", "and", "or",
    "but", "nor", "so", "yet", "for", "in", "on", "at", "to", "of", "by",
    "with", "from", "into", "over", "under", "about", "after", "before", "no",
    "not", "very", "too", "more", "most", "as", "if", "then", "than", "there",
    "here", "when", "where",
    # FR
    "le", "la", "les", "un", "une", "des", "du", "de", "ma", "mon", "mes",
    "ta", "ton", "tes", "sa", "son", "ses", "notre", "nos", "votre", "vos",
    "leur", "leurs", "je", "tu", "il", "elle", "nous", "vous", "ils", "elles",
    "on", "me", "te", "se", "lui", "y", "en", "et", "ou", "mais", "donc",
    "ni", "car", "si", "que", "qui", "quoi", "dont", "est", "sont", "suis",
    "es", "sommes", "êtes", "ont", "ai", "as", "avons", "avez", "avait",
    "était", "dans", "sur", "au", "aux", "pour", "par", "avec", "sans",
    "sous", "vers", "chez", "ne", "pas", "plus", "très", "trop", "bien",
    "déjà", "encore", "peut", "veut", "doit", "faut", "peux", "veux", "dois",
    "vais", "va", "vont", "fait", "font",
}

# Short words this speaker says that no list of function words holds. `pr` in
# "the sequence of pr proposed" is a pull request, not the start of "proposed".
# The transform cannot read vocabulary.yaml, so the escape hatch is here.
NEVER_START = {"pr", "prs", "qa", "ui", "ux", "id", "db", "os", "ci", "cd"}


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


def drop_restarts(text, applied):
    """A phrase begun, abandoned, and begun again — "in the ter in the terminal".

    The frame is the gate. `n-1` words match exactly and the last is a strict
    prefix of its counterpart, so the evidence is the repeat, not the prefix:
    "in the" == "in the" is what makes cutting `ter` safe. No word list is
    needed and none would help — 22 of the 30 archive fires have a partial that
    is an ordinary word (`the con`, `a vocab`, `it was broke`).

    30 fires over 8291 archive dictations, no failure found.
    """
    while True:
        words = list(WORD.finditer(text))
        tokens = [bare(w.group()) for w in words]
        edit = None

        for n in range(MAX_PHRASE, 1, -1):
            for i in range(len(tokens) - 2 * n + 1):
                if tokens[i:i + n - 1] != tokens[i + n:i + 2 * n - 1]:
                    continue
                begun, said = tokens[i + n - 1], tokens[i + 2 * n - 1]
                if len(begun) < 2 or begun == said or not said.startswith(begun):
                    continue
                if begun in NEVER_COLLAPSE or said in NEVER_COLLAPSE:
                    continue
                between = text[words[i + n - 1].end():words[i + n].start()]
                if SENTENCE_END.search(between):
                    continue
                edit = (i, n)
                break
            if edit:
                break

        if not edit:
            return text
        i, n = edit
        applied.append("phrase restarted")
        text = cut_to(text, words, i, i + n)


def drop_partials(text, applied):
    """A word begun, abandoned, and said in full — "co could you check".

    Two words, no frame, so the gate is the word itself. A function word before
    a longer word starting with the same letters is ordinary English — "one on
    one", "we were", "an answer", "il a acheté". The exception is a contraction:
    "it it's", "we we're", where the completion only adds an apostrophe.

    Measured over 8291 dictations: 142 bare fires, 55 after the list, 61 with
    the contraction rule, one failure — and the stop guard below catches it
    ("Don't worry about it. It'll ask").
    """
    while True:
        words = list(WORD.finditer(text))
        tokens = [bare(w.group()) for w in words]
        edit = None

        for i in range(len(tokens) - 1):
            begun, said = tokens[i], tokens[i + 1]
            if len(begun) < 2 or begun == said or not said.startswith(begun):
                continue
            if begun in NEVER_START or begun in NEVER_COLLAPSE:
                continue
            # The completion adds an apostrophe, so it is the same word with a
            # clitic on it. A hyphen is not enough: "peut peut-être" is two
            # words and "an anti-bounds" is a determiner.
            clitic = said[len(begun):len(begun) + 1] in ("'", "\u2019")
            if begun in FUNCTION_WORDS and not clitic:
                continue
            before = words[i - 1].group() if i > 0 else ""
            after = words[i + 2].group() if i + 2 < len(words) else ""
            if is_letter(before) or is_letter(after):
                continue
            if SENTENCE_END.search(text[words[i].end():words[i + 1].start()]):
                continue
            edit = i
            break

        if edit is None:
            return text
        applied.append("word restarted")
        text = cut_to(text, words, edit, edit + 1)


def cut_to(text, words, first, upto):
    """Delete `words[first:upto]`, keeping the case the first one carried."""
    head, tail = text[:words[first].start()], text[words[upto].start():]
    if words[first].group()[:1].isupper() and tail[:1].islower():
        tail = tail[:1].upper() + tail[1:]
    return head + tail


def collapse(text, applied):
    """Both passes, to a fixed point — a dropped fragment can expose a new
    repetition ("w we we can").

    `applied` is the list each pass names itself into, once per cut.
    """
    while True:
        out = collapse_repeats(
            drop_partials(drop_restarts(drop_fragments(text, applied), applied), applied),
            applied)
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


# ---------------------------------------------------------------- word fillers

# The markers each language has, and the form of the verb each is judged on.
# `like` has no verb, so it goes on its tag. A language with no entry has no
# filler rule.
MARKERS = {
    "en": {"i mean": "mean", "you know": "know", "like": None},
}

# Universal Dependencies relations, as the syrinx parse names them.
# The marker verb's own object. If it has one, the marker is doing work.
OBJECT = {"ccomp", "obj", "xcomp"}

# The marker sitting in one of these is an argument itself — "we'll let you know".
ARGUMENT = {"acl", "advcl", "ccomp", "conj", "csubj", "nmod", "obj", "obl", "xcomp"}

# A verb ("I like it"), a preposition ("like a cat") and a subordinator ("like
# I said") all stay.
LIKE_KEEPS = {"VERB", "AUX", "ADP", "SCONJ"}

# A marker the tag head puts in a correction stays (`in_correction`).
HOLD = 0.5
NEAR = 3

# Take the comma with the marker. Without this, "And you know, the comments
# should be" leaves "And, the comments should be" — 8 of 186 cuts did.
COMMA_BEFORE = re.compile(r"[,;]\s*$")
COMMA_AFTER = re.compile(r"^\s*[,;]")

# One word of the parse. `i` and `head` are the parse's 1-based indices,
# `start` and `end` offsets into the text the filler rule reads.
Word = namedtuple("Word", ("i", "text", "start", "end", "upos", "head", "dep"))


def fold(text):
    """Lower case, one code point for one: "İ".lower() is two."""
    return "".join(c.lower() if len(c.lower()) == 1 else c for c in text)


def placed(said, out, parse):
    """The parse's words that survive the string rules, placed in `out`.

    The parse is of `said`, the text this stage was handed. Every rule cuts
    whole tokens, the earlier copy, so the tokens of `out` are matched into
    those of `said` from the right: "foods like like Chi" keeps the second
    "like", and its parse. Tokens, not letters: matched letter by letter, the
    "e" of "like e every" was taken for the cut fragment. A parse word survives
    when every letter of it is in a matched token, so punctuation never does;
    the rule does not read it. Found by its spelling, not
    by `at`: `at` counts Characters, and Python counts code points. None when
    `out` is not `said` with tokens cut.
    """
    heard, to_out = list(WORD.finditer(said)), [None] * len(said)
    i = len(heard) - 1
    for token in reversed(list(WORD.finditer(out))):
        while i >= 0 and fold(heard[i].group()) != fold(token.group()):
            i -= 1
        if i < 0:
            return None
        to_out[heard[i].start():heard[i].end()] = range(token.start(), token.end())
        i -= 1
    words, cursor = [], 0
    for i, word in enumerate(parse["words"], 1):
        start = said.find(word["text"], cursor)
        if start < 0:
            return None
        cursor = start + len(word["text"])
        first = to_out[start]
        if first is None or any(to_out[k] != first + k - start for k in range(start, cursor)):
            continue
        words.append(Word(i, word["text"], first, first + cursor - start,
                          word["upos"], word["head"], word["deprel"]))
    return words


def tree_of(words, lo, hi):
    """The words of one sentence, offsets made relative to it.

    A long text is parsed in windows of several sentences with one root, so a
    word whose head is in another sentence, or was cut, is a root here. That is
    how a parse of the sentence alone would have it.
    """
    inside = [w for w in words if lo <= w.start < hi]
    ids = {w.i for w in inside}
    return [w._replace(start=w.start - lo, end=w.end - lo,
                       dep=w.dep if w.head in ids else "root") for w in inside]


def sentence_of(text, at, end):
    """The sentence holding the marker, and its offsets inside it.

    No `strip()`. Stripping moved every offset and made the cuts eat a letter —
    "So like a generation" came out "So la generation".
    """
    lo = max(text.rfind(c, 0, at) for c in ".?!") + 1
    after = [x for x in (text.find(c, end) for c in ".?!") if x >= 0]
    hi = (min(after) + 1) if after else len(text)
    return text[lo:hi], at - lo, end - lo, lo


def anchored(tree, verb, a, b):
    """The marker's OWN verb, not the sentence's first one.

    Looked up by span because a sentence can hold the same marker twice and
    mean different things by them: "You know, do you know who owns this
    account?" — the first is a filler and the second is the verb of the
    question. Matching on the form alone gave both the first one's verdict and
    cut both, which left "Do who owns this account?".
    """
    return next((w for w in tree
                 if a <= w.start < b and w.text.lower() == verb
                 and w.upos in ("VERB", "AUX")), None)


def substitution(tree, a, b):
    """A noun on both sides of the marker is a self-correction, not a filler.

    "I was with James I mean Peter, sorry" — deleting the marker leaves BOTH
    names, which is worse than leaving the sentence alone. `substitutions` runs
    above this and consumes these; this catches the ones it misses. Four of 186
    cuts, at the cost of one good cut.
    """
    outside = [w for w in tree if w.upos != "PUNCT" and (w.end <= a or w.start >= b)]
    before = [w for w in outside if w.start < a]
    after = [w for w in outside if w.start >= b]
    if not before or not after:
        return False
    return before[-1].upos in ("NOUN", "PROPN") and after[0].upos in ("NOUN", "PROPN")


def wants_cut(tree, marker, token, a, b):
    if marker == "like":
        return token is not None and token.upos not in LIKE_KEEPS
    if token is None:
        return False
    if any(w.head == token.i and w.dep in OBJECT for w in tree):
        return False
    if token.dep in ARGUMENT:
        return False
    return not substitution(tree, a, b)


def cut(sentence, spans):
    """Delete every marker in one sentence, and one adjacent comma each.

    All of them together, right to left. Done one at a time against the whole
    transcript, a second marker in the same sentence would splice a stale copy
    over the first cut — "So use like you know five lines" has two.

    Two things the sentence has to come back with. Its LEADING SPACE, which is
    the gap after the previous sentence's full stop: `sentence_of` starts the
    sentence right after that stop, so stripping here ran two sentences
    together — "goes right.you should". And its CAPITAL, when the marker that
    went was the first word: "I mean the hesitations part" has to come back as
    "The hesitations part", not "the".
    """
    lead = sentence[:len(sentence) - len(sentence.lstrip())]
    capitalised = sentence.lstrip()[:1].isupper()

    for a, b in sorted(spans, reverse=True):
        head, tail = sentence[:a], sentence[b:]
        if COMMA_AFTER.search(tail):
            tail = COMMA_AFTER.sub("", tail, count=1)
        elif COMMA_BEFORE.search(head):
            head = COMMA_BEFORE.sub("", head)
        if head.strip() and tail.strip() and not head[-1:].isspace() \
                and not tail[:1].isspace():
            head = head + " "
        sentence = head + tail

    body = re.sub(r"\s+([,.;?!])", r"\1", re.sub(r"[ \t]{2,}", " ", sentence)).lstrip()
    if capitalised and body[:1].islower():
        body = body[:1].upper() + body[1:]
    return lead + body


def marker_pattern(phrase):
    """The one pattern a marker is found by. Built here so the gate in `clean`
    and the search in `resolve` cannot drift apart."""
    return re.compile(r"\b" + phrase.replace(" ", r"\s+") + r"\b", re.I)


def in_correction(parse, words):
    """The parse indices of `words` the tag head puts in a correction the
    rules left: read as its cue, or within NEAR spoken words of a word read as
    abandoned.

    A marker there is the cue of "the rain, I mean the sun". Cut alone it
    leaves "the rain the sun", so it stays for the tree cutter.
    """
    names = parse["tag_names"]
    at_abandoned, at_cue = names.index("abandoned"), names.index("cue")
    spoken = [w.i for w in words if any(c.isalnum() for c in w.text)]
    tags = [parse["words"][i - 1]["tags"] for i in spoken]
    return {i for k, i in enumerate(spoken)
            if tags[k][at_cue] >= HOLD
            or any(t[at_abandoned] >= HOLD for t in tags[max(k - NEAR, 0):k + NEAR + 1])}


def resolve(text, markers, words, held=frozenset()):
    """Every marker judged against what was said, then cut a sentence at a time.

    Judged first because a cut changes the sentence the next marker is judged
    in. A marker with a word in `held` stays.
    """
    spans = []
    for phrase, verb in markers.items():
        for m in marker_pattern(phrase).finditer(text):
            sentence, a, b, offset = sentence_of(text, m.start(), m.end())
            tree = tree_of(words, offset, offset + len(sentence))
            if any(w.i in held for w in tree if a <= w.start < b):
                continue
            if verb is None:
                token = next((w for w in tree if w.start <= a < w.end), None)
                name = "like"
            else:
                token = anchored(tree, verb, a, b)
                name = phrase
            if wants_cut(tree, name, token, a, b):
                spans.append((m.start(), m.end(), phrase))
    return cut_spans(text, spans)


def cut_spans(text, spans):
    """Delete `(start, end, name)` spans of `text` with `cut`, a sentence at a
    time. Returns the text and the names, sentences from the right.

    Sentences replaced from the right because a cut moves every offset after
    it. A span across a stop gives a slice that overlaps the next sentence's,
    so overlapping slices become one.
    """
    slices = []
    for start, end, name in spans:
        sentence, _, _, lo = sentence_of(text, start, end)
        slices.append([lo, lo + len(sentence), [(start, end, name)]])
    merged = []
    for lo, hi, held in sorted(slices):
        if merged and lo < merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], hi)
            merged[-1][2].extend(held)
        else:
            merged.append([lo, hi, held])

    applied = []
    for lo, hi, held in reversed(merged):
        text = text[:lo] + cut(text[lo:hi], [(a - lo, b - lo) for a, b, _ in held]) + text[hi:]
        applied.extend(name for _, _, name in sorted(held))
    return text, applied


# ----------------------------------------------------------------- tree cutter

# Ported from training/syntax-parser, names and logic kept so the two diff by
# eye: syrinx_retrain/tags.py, audio_cue/candidates.py, audio_cue/cues.py,
# cut_check/candidates.py, cut_check/clf.py, cut_check/vec.py,
# cv_first_pass/heads.py, cv_first_pass/labels.py, weight_edit/evaluate.py.

OTHER, ABANDONED, CUE, REPAIR = range(4)
AFTER_CUES = {'no', 'sorry', 'non', 'pardon', 'perdón', 'perdon'}

CUE_MARKERS = [m.split() for m in ("i mean", "i meant", "no", "sorry", "or rather", "wait", "actually",
                                   "scratch that", "strike that")]

NEXT = 4
DIM = 384
THRESHOLD = 0.75
FILTER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cut-filter.json")

# `tokens`: the parse words with a letter or digit, which must all survive the
# rules. `held`: every parse word inside `words`, punctuation too, so "bor-"
# goes whole.
Proposal = namedtuple("Proposal", ("words", "tokens", "held", "score"))


def subtree(node, heads):
    found = {node}
    while True:
        extra = {i for i, h in enumerate(heads, 1) if h in found} - found
        if not extra:
            return found
        found |= extra


def is_filler(label, upos):
    return label == 'discourse' or upos == 'INTJ'


def gap_cues(gap, heads, labels, upos):
    """Filler words in the gap, plus the gap's non-punctuation words whose head chain reaches one
    without leaving the gap ("I" of "I mean", "de le" of "du coup")."""
    fillers = {j for j in gap if is_filler(labels[j - 1], upos[j - 1])}
    found = set(fillers)
    for j in gap:
        if j in fillers or upos[j - 1] == 'PUNCT':
            continue
        k = heads[j - 1]
        while k in gap and k not in fillers:
            k = heads[k - 1]
        if k in fillers:
            found.add(j)
    return found


def derive_tags(words, heads, labels, upos):
    """One tag index per word. Precedence: abandoned > cue > repair > other."""
    n = len(words)
    abandoned, cue, repair = set(), set(), set()
    for dep, (head, label) in enumerate(zip(heads, labels), 1):
        if label != 'reparandum' or head == 0:
            continue
        span = subtree(dep, heads)
        abandoned |= span
        repair.add(head)
        if head <= max(span):
            continue
        cue |= gap_cues(range(max(span) + 1, head), heads, labels, upos)
        k = head + 1
        while k <= n and upos[k - 1] == 'PUNCT':
            k += 1
        if (k <= n and is_filler(labels[k - 1], upos[k - 1]) and words[k - 1].casefold() in AFTER_CUES
                and k in subtree(head, heads)):
            cue.add(k)
    tags = [OTHER] * n
    for i in range(1, n + 1):
        if i in abandoned:
            tags[i - 1] = ABANDONED
        elif i in cue:
            tags[i - 1] = CUE
        elif i in repair:
            tags[i - 1] = REPAIR
    return tags


def cut_ids(tags, upos):
    """Word ids (1-based, punctuation excluded) the app would delete: abandoned and cue words."""
    return {i for i, (t, u) in enumerate(zip(tags, upos), 1) if t in (ABANDONED, CUE) and u != 'PUNCT'}


def groups(p):
    """[(token ids 1-based that are cut, repair heads)] per reparandum arc, chains and overlaps merged."""
    heads, labels, upos, ws = p['heads'], p['labels'], p['upos'], p['words']
    n = len(ws)
    cutset = cut_ids(derive_tags(ws, heads, labels, upos), upos)
    arcs = []
    for dep, (head, label) in enumerate(zip(heads, labels), 1):
        if label != 'reparandum' or head == 0:
            continue
        span = subtree(dep, heads)
        cues = set()
        if head > max(span):
            cues |= gap_cues(range(max(span) + 1, head), heads, labels, upos)
            k = head + 1
            while k <= n and upos[k - 1] == 'PUNCT':
                k += 1
            if (k <= n and is_filler(labels[k - 1], upos[k - 1]) and ws[k - 1].casefold() in AFTER_CUES
                    and k in subtree(head, heads)):
                cues.add(k)
        toks = (span | cues) & cutset
        if toks:
            arcs.append([toks, {head}])
    merged = True
    while merged:
        merged = False
        for i in range(len(arcs)):
            for j in range(i + 1, len(arcs)):
                a, b = arcs[i], arcs[j]
                if a[0] & b[0] or a[1] & b[0] or b[1] & a[0] or a[1] & b[1]:
                    arcs[i] = [a[0] | b[0], a[1] | b[1]]
                    del arcs[j]
                    merged = True
                    break
            if merged:
                break
    return arcs, cutset


def norm(word):
    return re.sub(r"[^\w']", '', word.casefold().replace('’', "'")).strip("'")


def words(text):
    """Whitespace words of a text with their character spans."""
    return [(m.group(), m.start(), m.end()) for m in re.finditer(r'\S+', text)]


def token_words(clip_parse):
    """For each parser token, the index of the whitespace word holding it, or None for punctuation."""
    text = clip_parse['text']
    out = []
    bounds = [(m.start(), m.end()) for m in re.finditer(r'\S+', text)]
    for (s, _), w in zip(clip_parse['spans'], clip_parse['words']):
        if not any(c.isalnum() for c in w):
            out.append(None)
            continue
        out.append(next(k for k, (a, b) in enumerate(bounds) if a <= s < b))
    return out


def text_cue(fn, cw, b):
    after = [fn[i] for i in range(b, min(len(fn), b + 2)) if i not in cw]
    seq = [fn[i] for i in cw] + ['|'] + after
    return int(any(seq[k:k + len(m)] == m for m in CUE_MARKERS for k in range(len(seq))))


def of_clip(p, text):
    """[candidate without a verdict] for one parsed text."""
    tw = p['tw']
    fn = [norm(w) for w, _, _ in words(text)]
    out = []
    for toks, _ in groups(p)[0]:
        cw = sorted({tw[t - 1] for t in toks if tw[t - 1] is not None})
        if not cw:
            continue
        b = cw[-1] + 1
        out.append(dict(a=cw[0], b=b, words=cw, contiguous=cw == list(range(cw[0], b)),
                        p_abandoned=[p['abandoned'][t - 1] for t in sorted(toks)], p_cue=[p['cue'][t - 1] for t in sorted(toks)],
                        text_cue=text_cue(fn, set(cw), b), at_end=b >= len(fn)))
    return out


def text_features(c):
    pa, pc = c['p_abandoned'], c['p_cue']
    return [max(pa), sum(pa) / len(pa), max(pc), math.log(len(c['words'])), float(c['text_cue']), float(c['contiguous']),
            float(c['at_end'])]


def word_vectors(vectors, tw, n):
    w, cnt = [[0.0] * DIM for _ in range(n)], [0] * n
    for t, i in enumerate(tw):
        if i is not None:
            w[i] = [x + y for x, y in zip(w[i], vectors[t])]
            cnt[i] += 1
    return w, cnt


def half(x):
    return struct.unpack('<e', struct.pack('<e', x))[0]


def of_cand(w, cnt, a, b):
    k = min(NEXT, b - a)

    def mean(idx):
        idx = [i for i in idx if i < len(cnt) and cnt[i] > 0]
        if not idx:
            return [0.0] * DIM
        total = sum(cnt[i] for i in idx)
        return [half(sum(w[i][d] for i in idx) / total) for d in range(DIM)]
    return mean(range(a, b)) + mean(range(b, b + k)) + mean([a - 1] if a > 0 else [])


_filter = None


def cut_filter(row):
    """V: P(real) = sigmoid(((x - mu) / sd) . w + b)."""
    global _filter
    if _filter is None:
        with open(FILTER) as f:
            _filter = json.load(f)
    m = _filter
    z = sum((x - mu) / sd * w for x, mu, sd, w in zip(row, m['mu'], m['sd'], m['w'])) + m['b']
    return 1 / (1 + math.exp(-z))


def clip_parse(said, parse):
    """The envelope's parse in the shape the training code reads, or None
    when a word is not in `said`. Offsets by spelling, as `placed` finds them."""
    names = parse["tag_names"]
    at_abandoned, at_cue = names.index("abandoned"), names.index("cue")
    p = dict(text=said, words=[], spans=[], heads=[], labels=[], upos=[], abandoned=[], cue=[])
    cursor = 0
    for word in parse["words"]:
        start = said.find(word["text"], cursor)
        if start < 0:
            return None
        cursor = start + len(word["text"])
        p['words'].append(word["text"])
        p['spans'].append((start, cursor))
        p['heads'].append(word["head"])
        p['labels'].append(word["deprel"])
        p['upos'].append(word["upos"])
        p['abandoned'].append(word["tags"][at_abandoned])
        p['cue'].append(word["tags"][at_cue])
    p['tw'] = token_words(p)
    return p


def proposals(said, parse):
    """Every tree cut of `said`, scored by V. Needs `parse: vectors`."""
    p = clip_parse(said, parse)
    if p is None:
        raise ValueError("the parse is of another text")
    vectors = [struct.unpack('<%de' % DIM, base64.b64decode(word["vector"])) for word in parse["words"]]
    bounds = words(said)
    w, cnt = word_vectors(vectors, p['tw'], len(bounds))
    ww = [next(k for k, (_, a, b) in enumerate(bounds) if a <= s < b) for s, _ in p['spans']]
    out = []
    for c in of_clip(p, said):
        row = text_features(c) + of_cand(w, cnt, c['a'], c['b'])
        cw = set(c['words'])
        tokens = [t for t, i in enumerate(p['tw'], 1) if i in cw]
        held = [t for t, k in enumerate(ww, 1) if k in cw]
        out.append(Proposal(c['words'], tokens, held, cut_filter(row)))
    return out


# The rules keep a doubled letter as a spelling, "it takes A A batteries", and
# so does the tree cutter. "I" is the one capital letter said as a word: "I I"
# is a stutter, and the parse reads it. Vetoing every guard instead cost 6
# fixes on AMI dev and saved no false cut.
SPELLING = ("spelled aloud", "a letter among letters")


def guarded(said, cw):
    """Whether the whitespace words `cw` of `said` are the first copy of a
    spelling the rules keep."""
    bounds = words(said)
    found = list(WORD.finditer(said))
    held = [k for k, m in enumerate(found)
            if any(bounds[i][1] <= m.start() < bounds[i][2] for i in cw)]
    if not held or held != list(range(held[0], held[-1] + 1)):
        return False
    i, n = held[0], len(held)
    tokens = [bare(m.group()) for m in found]
    if tokens[i:i + n] != tokens[i + n:i + 2 * n]:
        return False
    return set(tokens[i:i + n]) != {"i"} and protecting(tokens, i, n, said, found) in SPELLING


def tree_cut(said, out, parse):
    """Apply each proposal V keeps whose words all survived the rules and that
    is not a spelling. Returns the text, how many were applied, how many V
    dropped."""
    found = proposals(said, parse)
    survivors = placed(said, out, parse)
    if survivors is None:
        raise ValueError("the parse is of another text")
    alive = {w.i for w in survivors}
    spoken = {w.i for w in survivors if any(c.isalnum() for c in w.text)}
    gone, spans, applied, dropped = set(), [], 0, 0
    for proposal in found:
        if proposal.score < THRESHOLD:
            dropped += 1
            continue
        tokens = set(proposal.held)
        if not set(proposal.tokens) <= alive or tokens & gone or spoken <= gone | tokens:
            continue
        if guarded(said, proposal.words):
            continue
        gone |= tokens
        applied += 1
        run = None
        for w in survivors:
            if w.i not in tokens:
                run = None
            elif run is not None and not out[run[1]:w.start].strip():
                run[1] = w.end
            else:
                run = [w.start, w.end]
                spans.append(run)
    out, _ = cut_spans(out, [(a, b, "tree cut") for a, b in spans])
    return out, applied, dropped


def word_fillers(said, out, language, parse, applied):
    """The filler rule. Returns the text and why it was skipped, if it was."""
    markers = MARKERS.get(language, {})
    # Nothing said that a parse could judge. `resolve` builds these same
    # patterns and does nothing when none of them matches, so this cannot
    # change the text; it only keeps `declined` empty.
    if not any(marker_pattern(phrase).search(out) for phrase in markers):
        return out, ""
    if not parse:
        return out, "word fillers: no parse"
    try:
        found = placed(said, out, parse)
        if found is None:
            return out, "word fillers: the parse is of another text"
        out, marked = resolve(out, markers, found, in_correction(parse, found))
    except Exception as error:
        return out, "word fillers: %s" % error
    applied.extend(marked)
    return out, ""


def clean(text, language="en", parse=None, tally=None):
    """Every rule, in order. Returns the text, the passes that fired, and why
    a rule was skipped if one was. `tally`, a dict, gets `tree_cuts` and
    `tree_dropped` when the tree cutter ran.

    One entry point because `score.py` used to call `collapse` and so never ran
    the marker rule — the case set scored 91/100 against the module's own
    100/100, and the nine it missed were the only ones that need a parse.

    `parse` is the envelope's syrinx parse of `text`, or None.
    """
    applied = []
    try:
        out = collapse(text, applied)
        # The parse rule last: by now "I mean I mean" is one marker, and a
        # restart that hid a marker has been cleared out of the way.
        out, declined = word_fillers(text, out, language, parse, applied)
    except Exception:
        # Fail open — never drop the whole transcript because a guard threw.
        out, applied, declined = text, [], ""

    tokens = (parse or {}).get("words")
    if not tokens or not all("vector" in word for word in tokens):
        return out, applied, declined
    try:
        out, cuts, dropped = tree_cut(text, out, parse)
    except Exception as error:
        reason = "tree cut: %s" % (str(error) or type(error).__name__)
        return out, applied, "; ".join(filter(None, (declined, reason)))
    applied.extend(["tree cut"] * cuts)
    if tally is not None:
        tally.update(tree_cuts=cuts, tree_dropped=dropped)
    return out, applied, declined


def main():
    structured = os.environ.get("PARROTFLOW_PROTOCOL") == "json"
    raw = sys.stdin.read()
    payload = json.loads(raw) if structured else {"text": raw}

    tally = {}
    out, applied, declined = clean(
        payload["text"], (payload.get("ctx") or {}).get("language", "en"),
        payload.get("parse"), tally)

    if not structured:
        sys.stdout.write(out)
        if declined:
            sys.stderr.write(declined + "\n")
        return 0
    print(json.dumps({
        "text": out,
        # Deduplicated: three of the same fault name it once.
        "vars": {"applied": ", ".join(dict.fromkeys(applied)),
                 "edits": len(applied),
                 "declined": declined, **tally},
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
