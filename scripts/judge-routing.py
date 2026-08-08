#!/usr/bin/env python3
"""Score a *router* in front of the judge, against the menus already cached.

    scripts/judge-routing.py --classify-words     # NSSpellChecker, once, into YAML
    scripts/judge-routing.py --slots              # what each menu decomposes into
    scripts/judge-routing.py --sweep              # branch B alone, no model call
    scripts/judge-routing.py                      # the split, both branches, combined
    scripts/judge-routing.py --json out.json      # per-case results, for a diff later

`judge-framings.py` asked what happens when the judge's *question* changes.
Round 1's answer was that no wording wins, because two classes of case want
opposite things from one sentence (F17). This asks the next question: what if
the two classes never meet the same prompt?

The split under test is the one the app already owns, `Replacements.isRealWord`:

    the decoded word is NOT a real word    `Prizzi`, `Versal`, `RXV`, `Tasmin`
        Both spellings are spellings of one sound. There is no sentence to
        reason about. Decide in code: the better raw acoustic score wins.

    the decoded word IS a real word        `praise`, `crawl`, `update`, `press`
        Ask the judge one question — does a proper name belong in this
        position? — with no vocabulary list, because the list is what makes
        term-presence look like evidence of sense.

Three numbers are printed and all three are needed:

    branch B   the code arm, on the not-a-word subset
    branch A   the judge arm, on the is-a-word subset, four ways — two wordings
               of the position question, each as a whole sentence and as one
               blank per slot — plus the shipped prompt as the control
    combined   the two put together, against the shipped prompt with no router
               at all, measured in the same run, and against chance

Two routers are scored, and the arms are run once for both. `is-word` is the
gate the app ships. `is-word-lower` adds one test and was written after seeing
where the first one sent the wrong cases, which is stated in the report.

**The tuning set and the reporting set are the same 53 cases.** There is no
held-out set. A one- or two-case difference is inside the wording noise F16
measured, so a branch that moves by less than that has not moved.
"""
import argparse
import itertools
import json
import difflib
import os
import re
import subprocess
import sys
from pathlib import Path
from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "tests/judge-menus.json"
WORDS = ROOT / "tests/real-words.yaml"
CLASSIFIER = ROOT / "scripts/real-words.swift"

recall = SourceFileLoader("recall", str(ROOT / "scripts/menu-recall.py")).load_module()
tune = SourceFileLoader("tune", str(ROOT / "scripts/tune-judge.py")).load_module()
framings = SourceFileLoader("framings", str(ROOT / "scripts/judge-framings.py")).load_module()

COLLISIONS = framings.COLLISIONS


# ── the prompts ──────────────────────────────────────────────────────────────
# One wording, two forms. `{presented}` and `{pick}` are the only places the
# whole-sentence arm and the blank arm differ, and they differ in the *form*
# of the answer, not in what is asked. Keeping the rest one string is what
# makes a difference between the two a claim about the form.
#
# There is no vocabulary list. That is deliberate and it is half the design:
# on this branch the decoded word is a real English word, so the question is
# whether a *name* can stand there, and the list is what stops the judge from
# asking that (F17).
#
# The paragraph about "spells" is kept from the shipped prompt. It protects
# clips where the user is teaching a correction rather than dictating, and
# dropping it would confound this measurement with that one.

POSITION = """\
The user dictates text. The speech recogniser sometimes writes a proper name —
a person, a product, a brand — where the user said an ordinary English word.

So the only question is position. A name is not a verb: it cannot follow "to"
as an infinitive and it does not take -s or -ing the way a verb does. A name
does not modify a noun the way an adjective does. A name is not a preposition,
an article or a pronoun. Where the sentence needs an ordinary word to do its
work, an ordinary word is what the user said.

Sometimes the user is not dictating but teaching a correction — "urza spells
mirza", "Versal spells V E R C E L". The word before "spells" is the one they
want replaced later, so it has to survive now. Keep those readings as they are.

{presented}

Some come with a measure of how clearly the recogniser heard each spelling. A
gap under about 1 means the sound cannot tell them apart and the position has
to decide. A gap over about 4 means it can, and only a name standing where no
name can stand should overrule it.

{pick}"""

# The second wording of the same idea. F16 measured five wordings of one
# sentence spanning 38 to 42, so one wording is not a measurement of an idea.
# This one asks for the ruling-out rather than the picking, and names the
# failure instead of listing the parts of speech.
POSITION_2 = """\
The user dictates text. The speech recogniser sometimes writes a proper name —
a person, a product, a brand — where the user said an ordinary English word.

A name can only stand where a name can stand: as a subject, as an object, or
after a preposition. It cannot be the verb of the sentence, it cannot be the
word an adjective would fill, and it cannot be an article or a pronoun. A name
put anywhere else leaves a sentence no native speaker would produce.

Sometimes the user is not dictating but teaching a correction — "urza spells
mirza", "Versal spells V E R C E L". The word before "spells" is the one they
want replaced later, so it has to survive now. Keep those readings as they are.

{presented}

Some come with a measure of how clearly the recogniser heard each spelling. A
gap under about 1 means the sound cannot tell them apart and the position has
to decide. A gap over about 4 means it can, and only a name standing where no
name can stand should overrule it.

{pick}"""

SENTENCE_FORM = dict(
    presented="Below is the sentence, and every reading it might really have been.\n"
              "Exactly one is what the user said.",
    pick="Pick the reading in which every word stands where a word of its kind can\n"
         "stand, unless the sound says otherwise by more than about 4. Answer with\n"
         "its letter only.")

BLANK_FORM = dict(
    presented="Below is the sentence with one span left blank, and every reading that\n"
              "span might be. Exactly one is what the user said.",
    pick="Pick the reading that stands where a word of its kind can stand, unless\n"
         "the sound says otherwise by more than about 4. Answer with its letter\n"
         "only.")


# ── slots ────────────────────────────────────────────────────────────────────
# A menu is a cartesian product over the spans the spotter was unsure about.
# The cache does not record the spans — `VocabularyJudge` composes whole
# sentences and throws the combination away — so they are recovered by diffing
# the options against each other. `--slots` prints the result and `check()`
# refuses to run on a case whose product does not come back out to the menu.

def boundary_map(ref, toks):
    """Token boundary index in `ref` -> token boundary index in `toks`."""
    out = {}
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(
            a=ref, b=toks, autojunk=False).get_opcodes():
        if tag == "equal":
            for k in range(i2 - i1 + 1):
                out[i1 + k] = j1 + k
        else:
            out[i1], out[i2] = j1, j2
    out.setdefault(0, 0)
    out.setdefault(len(ref), len(toks))
    return out


def slots(menu):
    """(spans, fillers) — the uncertain spans, and each option's filler per span.

    Spans merge only when they genuinely overlap. Two slots that sit side by
    side stay two slots; a span that one option replaces with a different
    number of words stays one slot, however many words it holds. That is why
    a filler can be `praise the` or `on a file` and not only a single word.
    """
    ref = menu[0].split()
    raw = []
    for other in menu[1:]:
        for tag, i1, i2, _, _ in difflib.SequenceMatcher(
                a=ref, b=other.split(), autojunk=False).get_opcodes():
            if tag != "equal":
                raw.append((i1, max(i2, i1 + 1)))
    raw.sort()
    merged = []
    for a, b in raw:
        if merged and a < merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    spans = [tuple(s) for s in merged]

    fillers = []
    for option in menu:
        toks = option.split()
        at = boundary_map(ref, toks)
        fillers.append([" ".join(toks[at[a]:at[b]]) for a, b in spans])
    return ref, spans, fillers


def compose(ref, spans, fill):
    """`ref` with each span replaced by the given filler."""
    out, cursor = [], 0
    for (a, b), text in zip(spans, fill):
        out += ref[cursor:a]
        if text:
            out.append(text)
        cursor = b
    out += ref[cursor:]
    return " ".join(out)


def check(case, ref, spans, fillers):
    """The recovery is right only if it rebuilds the menu exactly.

    Two things are checked and both are needed. Every option must come back
    out of its own fillers, and the cartesian product of the slot options must
    be the menu — no reading missing, none invented. Counting readings is not
    enough: a misaligned span can hold the count and still cut the sentence in
    the wrong place, which would move a word into the wrong routing class and
    change the totals this file exists to report.
    """
    for option, fill in zip(case["menu"], fillers):
        rebuilt = compose(ref, spans, fill)
        if rebuilt != " ".join(option.split()):
            raise SystemExit(f"✗ {case['wav']}: {len(spans)} spans rebuild\n"
                             f"    {rebuilt!r}\n  from\n    {option!r}")
    options = [sorted({f[i] for f in fillers}) for i in range(len(spans))]
    built = {compose(ref, spans, combo) for combo in itertools.product(*options)}
    wanted = {" ".join(o.split()) for o in case["menu"]}
    if built != wanted:
        raise SystemExit(
            f"✗ {case['wav']}: the slot options do not span the menu.\n"
            f"  invented {sorted(built - wanted)}\n  missing {sorted(wanted - built)}")


def blank(ref, spans, index):
    """The sentence with slot `index` replaced by `___`, the others as decoded."""
    words, cursor, out = ref, 0, []
    for i, (a, b) in enumerate(spans):
        out += words[cursor:a]
        out.append("___" if i == index else " ".join(words[a:b]))
        cursor = b
    out += words[cursor:]
    return " ".join(out)


# ── the score block, per slot ────────────────────────────────────────────────

SCORE = re.compile(r'"(.+?)" (-?\d+\.\d+)\s+"(.+?)" (-?\d+\.\d+)')


def pairs(case):
    """[(heard, heardScore, term, termScore)] as `VocabularyJudge.scoreBlock` wrote them."""
    return [(h, float(hs), t, float(ts))
            for h, hs, t, ts in SCORE.findall(case.get("scores") or "")]


def slot_pair(case, options, heard):
    """The one score line that belongs to a slot, or None.

    A line names two spellings. A slot owns it when the decoded reading holds
    the heard spelling and some other reading of the same slot holds the term.
    Matched on the exact token first, then on letters alone and case-folded —
    the block prints `versal` where the menu prints `Versal`, and `retry.`
    beside `retry`, so one rule cannot serve both without going ambiguous.

    None means the slot cannot be settled by score, whatever the words are.
    That covers a slot the spotter proposed with no acoustic evidence, and a
    merged slot that holds two decisions and so matches two lines.
    """
    def tokens(text, fold):
        return {(bare(t).lower() if fold else t) for t in text.split()}

    for fold in (False, True):
        others = set().union(*[tokens(o, fold) for o in options if o != heard]) \
            if len(options) > 1 else set()
        mine = tokens(heard, fold)
        hit = [p for p in pairs(case)
               if (bare(p[0]).lower() if fold else p[0]) in mine
               and (bare(p[2]).lower() if fold else p[2]) in others]
        if len(hit) == 1:
            return hit[0]
    return None


def score_line(pair):
    """One slot's score line, in the wording `VocabularyJudge.scoreBlock` uses."""
    if pair is None:
        return ""
    h, hs, t, ts = pair
    return ("\n\nHow clearly the recogniser heard each spelling over that stretch of\n"
            "audio. Closer to zero is clearer, and the vocabulary's own bonus has been\n"
            "taken out, so the two are comparable.\n\n"
            f'  "{h}" {hs:.2f}   "{t}" {ts:.2f}   — "{t if ts < hs else h}" '
            f"heard {abs(hs - ts):.1f} less clearly")


def decoded_forms(case):
    """The surface forms the vocabulary proposed, so the rest is what was decoded."""
    forms = {f.strip() for f in case["terms"].split(",") if f.strip()}
    forms |= {framings.base_term(f) for f in forms}
    return {f for f in forms if f}


def bare(word):
    return "".join(ch for ch in word if ch.isalpha() or ch == " ").strip()


def decoded_filler(case, options):
    """Which of a slot's readings is the one the decoder actually wrote.

    Every other reading is a vocabulary term written in. A term form appearing
    anywhere in the filler disqualifies it, which is exact here because the
    proposals are the only thing that put those spellings on the menu.
    """
    terms = decoded_forms(case)

    def is_term(token):
        # `Matthieu's` and `Praisy,` are the term. The inflection and the
        # trailing mark come from the word it replaced, so an exact match
        # would miss most of them.
        return bool({token, bare(token), framings.base_term(token),
                     bare(framings.base_term(token))} & terms)

    plain = [o for o in options if not any(is_term(tok) for tok in o.split())]
    if len(plain) != 1:
        raise SystemExit(f"✗ {case['wav']}: {len(plain)} readings of {options} "
                         f"carry no vocabulary term; expected exactly 1")
    return plain[0]


# ── the router ───────────────────────────────────────────────────────────────

def load_words():
    if not WORDS.exists():
        raise SystemExit(f"✗ no {WORDS.relative_to(ROOT)} — run with --classify-words first")
    out = {}
    for line in WORDS.read_text().splitlines():
        line = line.split("#")[0].strip()
        if not line or ":" not in line:
            continue
        word, value = line.split(":", 1)
        if value.strip() in ("true", "false"):
            out[word.strip()] = value.strip() == "true"
    return out


def is_real_word(word, known):
    """`Replacements.isRealWord`, read out of the cached YAML.

    The app lowercases before it asks, and asks `en` then `fr`. Both of those
    live in `scripts/real-words.swift`; this only reproduces the caller's own
    handling of case, which `Vocabulary.autoApplies` does with `forms`.
    """
    letters = bare(word)
    if not letters:
        return False
    forms = [letters.lower()] if letters == letters.upper() else [letters, letters.lower()]
    for form in forms:
        if form not in known:
            raise SystemExit(f"✗ {form!r} is not in {WORDS.name} — rerun --classify-words")
        if known[form]:
            return True
    return False


# ── the run ──────────────────────────────────────────────────────────────────

def reachable(cases):
    keep = [c for c in cases
            if recall.normalise(c["said"]) in [recall.normalise(o) for o in c["menu"]]]
    return keep, len(cases) - len(keep)


def analyse(cases):
    """Everything the router needs, per case, computed once."""
    out = []
    for case in cases:
        ref, spans, fillers = slots(case["menu"])
        check(case, ref, spans, fillers)
        options = [sorted({f[i] for f in fillers}) for i in range(len(spans))]
        heard = [decoded_filler(case, o) for o in options]
        scored = [slot_pair(case, o, h) for o, h in zip(options, heard)]
        truth = None
        for option, filler in zip(case["menu"], fillers):
            if recall.normalise(option) == recall.normalise(case["said"]):
                truth = filler
        out.append(dict(case=case, ref=ref, spans=spans, fillers=fillers,
                        options=options, heard=heard, scored=scored, truth=truth))
    return out


def opens_a_sentence(item, index):
    """Is this slot the first word of its sentence?

    A capital there says nothing — every sentence starts with one. Anywhere
    else a capital is the decoder saying it heard a name, and that is the
    second routing test.

    The word before is read off `ref`, the first menu option. Every option
    agrees outside the spans, so that word is the same in all of them unless
    one slot begins where another ends. No menu in this cache does that —
    `slots` merges spans that touch through an overlap, and the ones left
    always have a fixed word between them.
    """
    start = item["spans"][index][0]
    return start == 0 or item["ref"][start - 1].endswith((".", "!", "?"))


def capitalised(item, index):
    word = item["heard"][index].split()[0]
    return word[:1].isupper() and not opens_a_sentence(item, index)


# Each router says why a *slot* needs a model. No reasons, and code can settle
# the case on its own. `is-word` is the gate the app ships. `is-word-lower`
# adds one test, and it was chosen after seeing this cache — see the report.
ROUTERS = {
    "is-word": "`Replacements.isRealWord` alone — the app's gate today",
    "is-word-lower": "the same, but a capital mid-sentence is not an ordinary word",
}


def route(item, router):
    """(branch, why) — 'code' only when every slot can be settled without a model."""
    reasons = []
    for i, heard in enumerate(item["heard"]):
        if item["scored"][i] is None:
            reasons.append(f"{heard!r} has no score line")
        elif " " in bare(heard):
            reasons.append(f"{heard!r} is more than one word")
        elif not is_real_word(heard, KNOWN):
            continue
        elif router == "is-word" or not capitalised(item, i):
            reasons.append(f"{heard!r} is a dictionary word")
    return ("judge" if reasons else "code"), reasons


def code_pick(item, index, offset=0.0):
    """The reading argmax raw score chooses for one slot, or None.

    `offset` is nats handed back to the term before the comparison. Zero is
    the raw comparison `Vocabulary.autoApplies` makes.

    The score block names a spelling; a slot holds a reading, and the two are
    not the same string. `praise` is the spelling and `praise the` is the
    reading, so the winner has to be mapped back onto the slot's own options
    or every multi-word span scores as wrong. An exact token beats a
    case-folded one, so `Praisy` lands on `Praisy` and not on `Praisy's`.
    """
    pair = item["scored"][index]
    if pair is None:
        return None
    heard, heard_score, term, term_score = pair
    winner = term if term_score + offset > heard_score else heard
    options = item["options"][index]
    for fold in (False, True):
        key = bare(winner).lower() if fold else winner
        hit = [o for o in options
               if key in {(bare(t).lower() if fold else t) for t in o.split()}]
        if len(hit) == 1:
            return hit[0]
    return None


def by_code(item, offset=0.0):
    """Branch B. Each slot takes the reading with the better raw score."""
    return [code_pick(item, i, offset) for i in range(len(item["spans"]))]


def sweep(items, offset):
    """Argmax with `offset` nats handed back to the term, per slot class.

    Round 1's PR #68 took the vocabulary bonus out of the score block so the
    two spellings would be comparable. This asks whether taking all of it out
    went too far: a constant put back is the smallest possible version of the
    bonus, and it costs no model call to try.
    """
    hit = {"not a word": [0, 0], "a dictionary word": [0, 0], "more than one word": [0, 0]}
    for item in items:
        for i, heard in enumerate(item["heard"]):
            if item["scored"][i] is None:
                continue
            name = ("more than one word" if " " in bare(heard)
                    else "a dictionary word" if is_real_word(heard, KNOWN)
                    else "not a word")
            hit[name][1] += 1
            hit[name][0] += code_pick(item, i, offset) == item["truth"][i]
    return hit


def by_judge(item, model, system, form):
    """Branch A. One call per case, or one call per slot in the blank form."""
    case = item["case"]
    if form == "sentence":
        chosen = tune.ask(model, system, case["menu"], case.get("scores") or "")
        if chosen is None:
            return None
        return item["fillers"][case["menu"].index(chosen)]
    picked = []
    for i, options in enumerate(item["options"]):
        lead = blank(item["ref"], item["spans"], i) + "\n\n"
        chosen = tune.ask(model, system, options,
                          score_line(item["scored"][i]), lead=lead)
        if chosen is None:
            return None
        picked.append(chosen)
    return picked


def stamp(case):
    return case["wav"][22:-4]


ARMS = {
    "shipped": dict(doc="today's prompt, whole-sentence menu — the control",
                    prompt=None, form="sentence"),
    "position": dict(doc="the position question, no term list, whole-sentence menu",
                     prompt=POSITION, form="sentence"),
    "position-2": dict(doc="the same idea, second wording, whole-sentence menu",
                       prompt=POSITION_2, form="sentence"),
    "position-blank": dict(doc="the position question, one blank per slot",
                           prompt=POSITION, form="blank"),
    "position-2-blank": dict(doc="the second wording, one blank per slot",
                             prompt=POSITION_2, form="blank"),
}


def system_for(arm, case):
    frame = ARMS[arm]
    if frame["prompt"] is None:
        return framings.build("baseline").replace("{terms}", case["terms"])
    return frame["prompt"].format(**(SENTENCE_FORM if frame["form"] == "sentence"
                                     else BLANK_FORM))


def classify_words(items):
    """Every decoded word the router will ask about, through NSSpellChecker once."""
    words = set()
    for item in items:
        for heard in item["heard"]:
            letters = bare(heard)
            if not letters or " " in letters:
                continue
            words.add(letters.lower())
            if letters != letters.upper():
                words.add(letters)
    ordered = sorted(words, key=str.lower)
    out = subprocess.run(["swift", str(CLASSIFIER), *ordered],
                         capture_output=True, text=True, check=True).stdout
    return ordered, out


KNOWN = {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.environ.get("PARROTFLOW_JUDGE_MODEL", "gemma4:e4b"))
    ap.add_argument("--arm", default="all", help="comma-separated arm names, or 'all'")
    ap.add_argument("--classify-words", action="store_true",
                    help="run scripts/real-words.swift over the decoded words and stop")
    ap.add_argument("--slots", action="store_true",
                    help="print what each menu decomposes into and stop")
    ap.add_argument("--sweep", action="store_true",
                    help="argmax with a constant handed back to the term, and stop")
    ap.add_argument("--json", metavar="PATH", help="write per-case results here")
    args = ap.parse_args()

    if not CACHE.exists():
        print("✗ no cache — run scripts/tune-judge.py --harvest first")
        return 2
    cases, unreachable = reachable(json.loads(CACHE.read_text()))
    items = analyse(cases)

    if args.classify_words:
        ordered, out = classify_words(items)
        print(f"# {len(ordered)} decoded words, NSSpellChecker, en then fr.")
        print("# Written by scripts/judge-routing.py --classify-words.")
        print(out, end="")
        return 0

    if args.slots:
        for item in items:
            print(f'{stamp(item["case"]):<10} menu={len(item["case"]["menu"]):>2} '
                  f'slots={len(item["spans"])}')
            for i, options in enumerate(item["options"]):
                print(f'    {blank(item["ref"], item["spans"], i)[:96]}')
                print(f'      options {options}  decoded {item["heard"][i]!r}')
        return 0

    global KNOWN
    KNOWN = load_words()

    if args.sweep:
        print("\n  argmax with a constant handed back to the term, by slot class.")
        print("  No model call anywhere in this table.\n")
        print(f"  {'offset':<8}{'not a word':<14}{'a dictionary word':<20}"
              f"{'more than one word':<20}")
        # The two ends are the two constant policies: -99 always keeps what the
        # decoder wrote, +99 always writes the term. They are the base rates the
        # middle of the table has to beat.
        for offset in [-99, 0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.5, 99]:
            row = sweep(items, offset)
            print(f"  {offset:<8.2f}"
                  + "".join(f"{f'{h}/{n}':<{w}}" for (h, n), w
                            in zip(row.values(), (14, 20, 20))))
        print("\n  The `not a word` column is the class the design sends to code."
              "\n  Every one of its slots was a term the speaker meant, so the column"
              "\n  only says how large a constant flips them. There is no case in it"
              "\n  where the decoded spelling was right, so nothing here can fail.\n")
        return 0

    chance = sum(1 / len(c["menu"]) for c in cases)
    print(f"\n  {len(cases)} reachable menus, {unreachable} never held the answer."
          f"  Judge {args.model}, temperature 0.")
    print(f"  Chance is {chance:.1f}/{len(cases)} (F13).")
    print(f"  The same {len(cases)} cases are tuned on and reported on."
          " There is no held-out set.\n")

    # ── every arm, on every case ─────────────────────────────────────────────
    # Scored on all 53 first, then a router only decides which half of each
    # arm counts. That way two routers cost no extra model calls, and the
    # control is measured in the same run rather than carried over from round
    # 1 — the judge is sampled, and comparing a fresh arm with a remembered
    # number is how wording noise becomes a finding.
    names = list(ARMS) if args.arm == "all" else [n.strip() for n in args.arm.split(",")]
    for name in names:
        if name not in ARMS:
            print(f"✗ no arm {name!r}; known: {', '.join(ARMS)}")
            return 2
    for item in items:
        item["code_right"] = (by_code(item) == item["truth"]
                              if all(item["scored"]) else None)
    stray = {}
    for name in names:
        before = len(tune.STRAY)
        for item in items:
            item[name] = by_judge(item, args.model, system_for(name, item["case"]),
                                  ARMS[name]["form"]) == item["truth"]
        stray[name] = len(tune.STRAY) - before
    control53 = sum(i["shipped"] for i in items) if "shipped" in names else None
    if any(stray.values()):
        print("  replies with no bare letter — "
              + ", ".join(f"{n} {c}" for n, c in stray.items() if c) + "\n")

    # ── the slot tally ───────────────────────────────────────────────────────
    # A case goes to code only when *every* slot can. The slot tally says how
    # far that is from the per-slot picture.
    # `argmax` is counted on every class, not only on the class the design
    # sends to code. That is the comparison the design rests on: the claim is
    # that a non-word slot has nothing to reason about, so the sound should
    # win there and only there.
    classes = ["not a word, scored", "a dictionary word, capitalised",
               "a dictionary word, lower case", "more than one word", "no score line"]
    tally = {c: [0, 0, 0] for c in classes}       # slots, argmax right, argmax possible
    for item in items:
        for i, heard in enumerate(item["heard"]):
            pair = item["scored"][i]
            if pair is None:
                name = "no score line"
            elif " " in bare(heard):
                name = "more than one word"
            elif is_real_word(heard, KNOWN):
                name = ("a dictionary word, capitalised" if capitalised(item, i)
                        else "a dictionary word, lower case")
            else:
                name = "not a word, scored"
            row = tally[name]
            row[0] += 1
            if pair is not None:
                row[2] += 1
                row[1] += code_pick(item, i) == item["truth"][i]
    print(f"  by slot, not by case — {sum(r[0] for r in tally.values())} uncertain "
          f"slots over the {len(cases)} cases,")
    print("  and what argmax raw score alone would have done with each\n")
    for name in classes:
        slot_count, hit, seen = tally[name]
        got = f"argmax {hit}/{seen}" if seen else "argmax cannot run"
        print(f"    {slot_count:>3}  {name:<32} {got}")

    # Why branch B cannot win, stated as a count rather than as an argument.
    #
    # `Vocabulary.autoApplies` fires when the term beats the decoded word on
    # the raw score AND the decoded word is not a real word. So a menu only
    # exists where one of those failed. On the not-a-word class the second
    # test passed, so the first must have failed — the decoded spelling scores
    # at least as well as the term, always. Argmax on that class can only ever
    # answer "keep what was decoded". It is not a weak signal there; it is the
    # residue of a decision the app already took.
    kept, of = 0, 0
    for item in items:
        for i, heard in enumerate(item["heard"]):
            pair = item["scored"][i]
            if pair is None or " " in bare(heard) or is_real_word(heard, KNOWN):
                continue
            of += 1
            kept += pair[1] >= pair[3]
    print(f"\n  on {kept} of those {of} slots the decoded spelling already scores"
          " at least as well as\n  the term. `Vocabulary.autoApplies` guarantees it:"
          " a slot reaches a menu only when\n  the term lost on score or the decoded"
          " word is real, and here the word is not real.\n")

    if control53 is not None:
        print(f"  control   today's prompt, no router, all {len(cases)}   "
              f"{control53}/{len(cases)}   (round 1 recorded 41)")

    # ── one block per router ─────────────────────────────────────────────────
    for router, doc in ROUTERS.items():
        for item in items:
            item["branch"], item["why"] = route(item, router)
        code = [i for i in items if i["branch"] == "code"]
        judge = [i for i in items if i["branch"] == "judge"]
        multi = [i for i in judge if len(i["spans"]) > 1]
        noscore = [i for i in judge if any(s is None for s in i["scored"])]
        right = sum(i["code_right"] for i in code)

        print(f"\n\n  ══ router {router!r} — {doc}\n")
        print(f"  branch B, decided in code   {len(code):>2} cases"
              f"   {right} right   (chance "
              f"{sum(1 / len(i['case']['menu']) for i in code):.1f})")
        print(f"  branch A, asked of a judge  {len(judge):>2} cases"
              f"   ({len(multi)} hold more than one slot, {len(noscore)} hold a slot"
              f" with no score line)")
        print(f"  branch A chance {sum(1 / len(i['case']['menu']) for i in judge):.1f}\n")
        for name in names:
            got = sum(item[name] for item in judge)
            print(f"  {name:<18} branch A {got:>2}/{len(judge):<3}"
                  f" multi-slot {sum(i[name] for i in multi)}/{len(multi):<3}"
                  f" combined {right + got:>2}/{len(cases)}"
                  + (f"   (no router {control53})" if control53 is not None else ""))

        control = names[0]
        if len(names) > 1:
            print(f"\n  branch A per case, against {control!r} — + won, - lost\n")
            for name in names[1:]:
                won = [stamp(i["case"]) for i in judge if i[name] and not i[control]]
                lost = [stamp(i["case"]) for i in judge if i[control] and not i[name]]
                print(f"  {name:<18} +{len(won)} {' '.join(won) or '-'}")
                print(f"  {'':<18} -{len(lost)} {' '.join(lost) or '-'}")

        # ── the routing errors ───────────────────────────────────────────────
        print("\n  routing errors — cases this split sent the wrong way\n")
        wrong = []
        for item in code:
            if not item["code_right"]:
                wrong.append(("sent to code, and code got it wrong", item))
        for item in judge:
            for i, heard in enumerate(item["heard"]):
                pair = item["scored"][i]
                if (pair and " " not in bare(heard) and is_real_word(heard, KNOWN)
                        and item["truth"][i] != heard):
                    wrong.append((
                        f"sent to the judge because {heard!r} is in the dictionary — "
                        f"but nobody said it", item))
                    break
        for why, item in wrong:
            case = item["case"]
            print(f'  {stamp(case)}  {why}')
            print(f'      said     {case["said"]}')
            for i, options in enumerate(item["options"]):
                print(f'      slot {i}   {options}  decoded {item["heard"][i]!r}'
                      f'  true {item["truth"][i]!r}')
        print(f"\n  {len(wrong)} of {len(cases)} cases misrouted.")

        # ── the collision class ──────────────────────────────────────────────
        print(f"\n  the ordinary-word collision class — {len(COLLISIONS)} clips, PR #68\n")
        at = {stamp(i["case"]): i for i in items}
        print("  " + f"{'clip':<10}{'branch':<8}" + "".join(f"{n[:15]:<17}" for n in names))
        for clip, what in COLLISIONS.items():
            item = at.get(clip)
            if item is None:
                print(f"  {clip:<10}unreachable — never on the menu")
                continue
            marks = (f"code {'✓' if item['code_right'] else '✗'}"
                     if item["branch"] == "code"
                     else "".join(f"{'✓' if item[n] else '✗':<17}" for n in names))
            print(f"  {clip:<10}{item['branch']:<8}{marks}   {what}")
        scored_clips = [at[c] for c in COLLISIONS if c in at]
        totals = []
        for name in names:
            got = sum(i["code_right"] if i["branch"] == "code" else i[name]
                      for i in scored_clips)
            totals.append(f"{got}/{len(scored_clips)}")
        print("  " + f"{'total':<10}{'':<8}" + "".join(f"{t:<17}" for t in totals))

        if args.json:
            path = Path(args.json)
            path = path.with_name(f"{path.stem}-{router}{path.suffix}")
            path.write_text(json.dumps(
                [{"wav": i["case"]["wav"], "branch": i["branch"], "why": i["why"],
                  "options": i["options"], "decoded": i["heard"], "true": i["truth"],
                  "code": i["code_right"], **{n: i[n] for n in names}}
                 for i in items], indent=1, ensure_ascii=False))
            print(f"\n  per-case results written to {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
