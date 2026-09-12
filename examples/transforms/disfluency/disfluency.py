#!/usr/bin/env python3
"""What the speaker did not mean to say, taken out. Transcript on stdin,
rewrite on stdout.

    - name: disfluency
      description: delete hesitations, repeats and false starts
      command: disfluency.py
      returns: json

Four rules, in this order:

    repeats        an exact copy of what is already there — "the the prompt"
    fragments      a single letter begun and restarted — "w we can try"
    restarts       a phrase begun and begun again — "in the ter in the terminal"
    partials       a word begun and said in full — "co could you check"
    word fillers   a marker that carries nothing — "so use like you know five"

The first four are string work: no model, no network, and they run on every
transcript. The fifth needs a dependency parse, because "you know" is a real
verb with a real object half the time — "we'll let you know" must survive. It
is skipped, and says so, when spaCy is not installed.

`returns: json` publishes `disfluency.applied`, the passes that fired, and
`disfluency.edits`, how many cuts they made.

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

# A clause marker and the verb the test is run on.
CLAUSE = {"i mean": "mean", "you know": "know"}

# Hedges. Read only with --hedges: deleting one changes what was claimed.
HEDGES = {"i think": "think", "i guess": "guess", "i would say": "say"}

# The marker verb's own object. If it has one, the marker is doing work.
OBJECT = {"ccomp", "dobj", "obj", "xcomp", "acomp", "attr", "oprd"}

# The marker sitting in one of these is an object itself — "we'll let you know".
ARGUMENT = {"ccomp", "xcomp", "relcl", "advcl", "csubj", "pobj", "conj", "acl",
            "dobj", "obj"}

# `like` has no verb to test, so it goes on the tag. A verb ("I like it"), a
# preposition ("like a cat") and a subordinator ("like I said") all stay.
LIKE_KEEPS = {"VERB", "AUX", "ADP", "SCONJ"}

# Take the comma with the marker. Without this, "And you know, the comments
# should be" leaves "And, the comments should be" — 8 of 186 cuts did.
COMMA_BEFORE = re.compile(r"[,;]\s*$")
COMMA_AFTER = re.compile(r"^\s*[,;]")


def sentence_of(text, at, end):
    """The sentence holding the marker, and its offsets inside it.

    No `strip()`. Stripping moved every offset and made the cuts eat a letter —
    "So like a generation" came out "So la generation".
    """
    lo = max(text.rfind(c, 0, at) for c in ".?!") + 1
    after = [x for x in (text.find(c, end) for c in ".?!") if x >= 0]
    hi = (min(after) + 1) if after else len(text)
    return text[lo:hi], at - lo, end - lo, lo


def anchored(doc, lemma, a, b):
    """The marker's OWN verb, not the sentence's first one.

    Looked up by span because a sentence can hold the same marker twice and
    mean different things by them: "You know, do you know who owns this
    account?" — the first is a filler and the second is the verb of the
    question. Matching on lemma alone gave both the first one's verdict and cut
    both, which left "Do who owns this account?".
    """
    return next((t for t in doc
                 if a <= t.idx < b and t.lemma_ == lemma
                 and t.pos_ in ("VERB", "AUX")), None)


def substitution(doc, a, b):
    """A noun on both sides of the marker is a self-correction, not a filler.

    "I was with James I mean Peter, sorry" — deleting the marker leaves BOTH
    names, which is worse than leaving the sentence alone. `substitutions` runs
    above this and consumes these; this catches the ones it misses. Four of 186
    cuts, at the cost of one good cut.
    """
    outside = [t for t in doc if not t.is_punct and (t.idx + len(t.text) <= a or t.idx >= b)]
    before = [t for t in outside if t.idx < a]
    after = [t for t in outside if t.idx >= b]
    if not before or not after:
        return False
    return before[-1].pos_ in ("NOUN", "PROPN") and after[0].pos_ in ("NOUN", "PROPN")


def wants_cut(doc, marker, token, a, b):
    if marker == "like":
        return token is not None and token.pos_ not in LIKE_KEEPS
    if token is None:
        return False
    if any(c.dep_ in OBJECT for c in token.children):
        return False
    if token.dep_ in ARGUMENT:
        return False
    return not substitution(doc, a, b)


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


def resolve(text, markers, nlp):
    """Every marker judged against what was said, then cut a sentence at a time.

    Judged first because a cut changes the parse of its own sentence. Sentences
    replaced from the right because a cut moves every offset after it.
    """
    per_sentence = {}
    for phrase, lemma in markers.items():
        for m in marker_pattern(phrase).finditer(text):
            sentence, a, b, offset = sentence_of(text, m.start(), m.end())
            doc = nlp(sentence)
            if lemma is None:
                token = next((t for t in doc if t.idx <= a < t.idx + len(t.text)), None)
                name = "like"
            else:
                token = anchored(doc, lemma, a, b)
                name = phrase
            if wants_cut(doc, name, token, a, b):
                slot = per_sentence.setdefault(offset, [sentence, []])
                slot[1].append((a, b, phrase))

    applied = []
    for offset in sorted(per_sentence, reverse=True):
        sentence, spans = per_sentence[offset]
        text = text[:offset] + cut(sentence, [(a, b) for a, b, _ in spans]) \
            + text[offset + len(sentence):]
        applied.extend(p for _, _, p in sorted(spans))
    return text, applied


def spacy_or_none():
    """spaCy, if this Mac has it.

    `ParrotFlow --setup-parsing` builds a venv under Application Support, and
    the app runs a transform through whichever `python3` it resolved — which is
    not that venv. So look inside it, but only for a matching version: a
    site-packages built for 3.13 holds C extensions a 3.12 cannot load.
    """
    try:
        import spacy
        return spacy
    except ImportError:
        pass
    version = "python%d.%d" % sys.version_info[:2]
    site = os.path.expanduser(
        "~/Library/Application Support/ParrotFlow/python/lib/%s/site-packages" % version)
    if not os.path.isdir(site):
        return None
    sys.path.append(site)
    try:
        import spacy
        return spacy
    except Exception:
        return None


def clean(text, language="en"):
    """Every rule, in order. Returns the text, the passes that fired, and why
    a rule was skipped if one was.

    One entry point because `score.py` used to call `collapse` and so never ran
    the marker rule — the case set scored 91/100 against the module's own
    100/100, and the nine it missed were the only ones that need a parse.
    """
    applied = []
    declined = ""
    try:
        out = collapse(text, applied)
    except Exception:
        # Fail open — never drop the whole transcript because a guard threw.
        return text, [], ""

    # The parse rule last: by now "I mean I mean" is one marker, and a restart
    # that hid a marker has been cleared out of the way.
    if language != "en":
        return out, applied, ""
    markers = dict(CLAUSE)
    markers["like"] = None

    # Nothing said that a parse could judge, so nothing is loaded. `resolve`
    # builds these same patterns and does nothing when none of them matches,
    # so this cannot change the text. It skips `import spacy` and a model
    # load — measured 0.53s and 0.21s, against 0.04s for the rest of this
    # file — on every dictation that carries no marker at all.
    if not any(marker_pattern(phrase).search(out) for phrase in markers):
        return out, applied, ""

    spacy = spacy_or_none()
    if spacy is None:
        return out, applied, "word fillers: no spacy — run ParrotFlow --setup-parsing"
    try:
        out, marked = resolve(out, markers, spacy.load("en_core_web_sm"))
        applied.extend(marked)
    except Exception as error:
        declined = "word fillers: %s" % error
    return out, applied, declined


def main():
    structured = os.environ.get("PARROTFLOW_PROTOCOL") == "json"
    raw = sys.stdin.read()
    payload = json.loads(raw) if structured else {"text": raw}

    out, applied, declined = clean(
        payload["text"], (payload.get("ctx") or {}).get("language", "en"))

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
                 "declined": declined},
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
