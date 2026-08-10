#!/usr/bin/env python3
"""Score named ways of *asking* the judge, against the menus already cached.

    scripts/judge-framings.py --classify          # label the vocabulary terms once
    scripts/judge-framings.py                     # every framing, one table
    scripts/judge-framings.py --framing baseline,invert-ported
    scripts/judge-framings.py --json out.json     # per-case results, for a diff later

`tune-judge.py` answers "is this prompt file better". This answers a narrower
question: the judge's errors nearly all belong to one class — an ordinary
English word colliding with a vocabulary term, and the term winning — so what
happens if the *question* changes rather than its wording?

Each framing is an edit list applied to the shipped `verify_names.md`, plus a
way of rendering the term list. Nothing here writes a prompt file, and nothing
here changes the app. The edits are exact substrings of the shipped prompt and
the run fails loudly if one stops matching, so a framing can never quietly
become "the shipped prompt again".

Three things are printed and all three are needed:

    picked   of the menus that held the true sentence, how many were chosen
    chance   what guessing one letter scores on these menu sizes (F13)
    diff     which clips each framing wins and loses against the baseline

**The tuning set and the reporting set are the same 53 cases.** There is no
held-out set. A one- or two-case difference is inside the wording noise F16
measured (five wordings of one sentence spanned 38 to 41), so a framing that
moves by less than that has not moved.

Deferred, deliberately not implemented here: cloze menus (one blank per
uncertain slot, letters answered per blank), cloze scored by logprob, fusion
with the acoustic margin, and an NLTagger part-of-speech signal. The first two
are not prompt changes — the stage composes whole sentences today, so a blank
means rewriting how `VocabularyJudge` builds its question. `FRAMINGS` is a
plain registry so they can be added beside these without moving anything.
"""
import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path
from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "tests/judge-menus.json"
PROMPT = ROOT / "examples/prompts/verify_names.md"
KINDS = ROOT / "tests/term-kinds.yaml"
ENDPOINT = os.environ.get("PARROTFLOW_LLM_ENDPOINT", "http://localhost:11434") + "/api/chat"

recall = SourceFileLoader("recall", str(ROOT / "scripts/menu-recall.py")).load_module()
# `ask` (one call, the app's own letter rule) and `chosen` live there and are
# not restated here — a harness that reads a reply differently from the app is
# scoring a choice nobody ships.
tune = SourceFileLoader("tune", str(ROOT / "scripts/tune-judge.py")).load_module()


# ── the class this file exists for ───────────────────────────────────────────
# The nine rows PR #68 recorded as regressed by the vocabulary pass: an
# ordinary English word overwritten by a term, waved through by the judge.
# Five of them are also the controls that sit at `~` in `menu-recall.py`
# (marked below). A total over 53 cases can improve while these get worse,
# which is the whole reason they are tallied on their own.

COLLISIONS = {
    "17-47-45": "retry/crawl        -> Arexvy/Redcrawl",
    "09-35-01": "Versailles castle  -> Vercel castle",
    "14-04-21": "explanations to update -> Praisy to Supabase",   # control at ~
    "10-12-37": "asked me to crawl  -> to Redcrawl",
    "14-09-56": "near matches       -> near Matthieu",            # control at ~
    "13-09-46": "praise for shipping -> Praisy shipping",         # control at ~
    "11-19-17": "proprietary term   -> Praisy term",              # control at ~
    "15-36-12": "Pretty harsh       -> Arexvy harsh",             # control at ~
    "14-11-21": "the crawl data     -> the Redcrawl data",
}


# ── pieces of the shipped prompt, quoted exactly ─────────────────────────────
# Line breaks included. These are the seams every framing cuts on.

ENUMERATION = ("Their vocabulary includes: {terms} — colleagues, products and tools they talk\n"
               "about every day.")

THAT_LIST = "That list is not everyone they know."

PICK = ("Pick the reading that makes sense as a sentence, unless the sound says\n"
        "otherwise by more than about 4. Answer with its letter only.")

# The clause that ties the answer to the acoustic block. Every framing keeps
# it, so the only thing changing between them is the question itself.
TAIL = "unless the sound says otherwise by more than about 4"


# ── framings ─────────────────────────────────────────────────────────────────
# `edits`  exact (old, new) substitutions on the shipped prompt, applied in order
# `terms`  "bare" (the shipped comma list) or "typed" (each name with its kind)
#
# The three `invert-*` framings are one hypothesis in three wordings. F16
# measured wording at up to 4 cases inside one idea, so a single wording is not
# a measurement of the idea.

INVERT_PORTED = (
    "Every reading but one contains a speech-recognition error: a proper name or\n"
    "product name written where an ordinary English word was actually spoken,\n"
    "leaving a sentence that does not parse. Rule those readings out. Answer with\n"
    "the letter of the one that is left, " + TAIL + ".")

INVERT_SHORT = (
    "All but one of these readings contain a transcription error. Rule them out.\n"
    "Answer with the letter of the one that does not, " + TAIL + ".")

INVERT_LONG = (
    "In all but one of these readings, a brand, product or person's name is\n"
    "printed where the speaker actually said a common English word, or two common\n"
    "words have been run together into a single name — leaving a sentence a native\n"
    "speaker would never produce. Find those readings and rule them out. Answer\n"
    "with the letter of the reading that is left, " + TAIL + ".")

# Typing the names is only half of H2. This sentence is the other half: it asks
# a question about position, which is the thing a plausibility prior cannot
# answer. It goes in as its own paragraph, before the instruction to pick.
SLOT_RULE = (
    "Each name above is labelled with what kind of thing it is. A name can only\n"
    "stand where a name of that kind can stand. A product, a brand or a drug is\n"
    "not a verb, so it cannot follow \"to\" as an infinitive, and it does not\n"
    "modify a noun the way an adjective does. A person is not an adjective\n"
    "either. A reading that puts a name in a position no name of its kind can\n"
    "occupy is not what the user said.\n\n")

# The same rule with the kinds taken out. `typed-slot` changes two things at
# once — the labels and the question — and this is the half that needs no
# labels, so it says which half did the work. It is also the only form of the
# rule that can be combined with cutting the term list, because a name cannot
# be labelled and withheld at the same time.
SLOT_RULE_PLAIN = (
    "A name can only stand where a name can stand. A name is not a verb, so it\n"
    "cannot follow \"to\" as an infinitive, and it does not modify a noun the way\n"
    "an adjective does. A reading that puts a name in a position no name can\n"
    "occupy is not what the user said.\n\n")

# Deleting the enumeration outright, and repairing the sentence that pointed
# at it. Two framings share this, so it is written once.
CUT_EDITS = [
    ("The user dictates text. The speech recogniser mangles names they use often.\n"
     + ENUMERATION,
     "The user dictates text. The speech recogniser mangles names they use often."),
    (THAT_LIST, "Their vocabulary is not everyone they know."),
]

FRAMINGS = {
    "baseline": dict(
        doc="the shipped prompt, unchanged — the control",
        edits=[], terms="bare"),

    # H1: the list is the prior. F14 measured the same shape in a reranker
    # query, where listing the vocabulary scored below chance.
    "no-terms": dict(
        doc="the same prompt with the names not enumerated",
        edits=[(ENUMERATION,
                "Their vocabulary includes colleagues, products and tools they talk about\n"
                "every day. The names in it are not listed here.")],
        terms="bare"),
    "no-terms-cut": dict(
        doc="the enumeration sentence deleted outright",
        edits=CUT_EDITS, terms="bare"),

    # H2 via polarity: ask which reading is wrong, keep the other. Ported from
    # `rerank-judge.py`'s `misheard`, `misheard-short` and `misheard-long`.
    "invert-ported": dict(
        doc="which readings contain a misrecognition; take the one left",
        edits=[(PICK, INVERT_PORTED)], terms="bare"),
    "invert-short": dict(
        doc="the same, said in two sentences",
        edits=[(PICK, INVERT_SHORT)], terms="bare"),
    "invert-long": dict(
        doc="the same, spelled out",
        edits=[(PICK, INVERT_LONG)], terms="bare"),

    # H2 via syntax: the names carry a kind, and the question is whether a name
    # of that kind fits the slot.
    "typed": dict(
        doc="the same prompt, names labelled with their kind",
        edits=[], terms="typed"),
    "typed-slot": dict(
        doc="typed names, plus the rule that a kind has positions",
        edits=[(PICK, SLOT_RULE + PICK)], terms="typed"),

    # Run only after the arms above, and only because two of them moved the
    # collision class. `slot-only` splits `typed-slot` in half; `no-terms-slot`
    # is the one combination the two winners allow.
    "slot-only": dict(
        doc="the bare list, plus the position rule with no kinds",
        edits=[(PICK, SLOT_RULE_PLAIN + PICK)], terms="bare"),
    "no-terms-slot": dict(
        doc="no enumeration, plus the position rule with no kinds",
        edits=CUT_EDITS + [(PICK, SLOT_RULE_PLAIN + PICK)],
        terms="bare"),
}


def build(framing):
    """The shipped prompt with this framing's edits applied.

    Every edit must match exactly once. A silently missing edit turns a
    framing into the baseline and reports it as a finding, which is the one
    failure this harness cannot be allowed to have.
    """
    text = PROMPT.read_text().strip()
    for old, new in FRAMINGS[framing]["edits"]:
        if text.count(old) != 1:
            raise SystemExit(
                f"✗ framing {framing!r}: its edit no longer matches "
                f"{PROMPT.name} exactly once ({text.count(old)} times).\n"
                f"   looked for: {old[:60]!r}...")
        text = text.replace(old, new)
    return text


# ── the term kinds ───────────────────────────────────────────────────────────

ARTICLE = {"a": "an", "e": "an", "i": "an", "o": "an", "u": "an"}
CLASSES = ["person", "product", "brand", "drug", "tool", "company"]


def base_term(form):
    """`Praisy's` and `Arexvy.` and `Vercel?` are all one term.

    The cached `terms` string is what the app put in the system message, and
    that carries the inflected surface forms the router proposed.
    """
    word = form.strip().rstrip(".?!,;:")
    for suffix in ("'s", "’s"):
        if word.endswith(suffix):
            word = word[: -len(suffix)]
    return word


def load_kinds():
    """term -> kind, from the YAML `--classify` writes.

    Parsed by hand. The repo has no YAML dependency and this file is two
    columns; `menu-recall.load_cases` makes the same choice for the same
    reason.
    """
    if not KINDS.exists():
        raise SystemExit(f"✗ no {KINDS.relative_to(ROOT)} — run with --classify first")
    kinds = {}
    for line in KINDS.read_text().splitlines():
        line = line.split("#")[0].strip()
        if not line or ":" not in line:
            continue
        term, kind = line.split(":", 1)
        if kind.strip():
            kinds[term.strip()] = kind.strip()
    return kinds


def render_terms(raw, style, kinds):
    """The term list as the system message will carry it."""
    if style == "bare" or not raw:
        return raw
    out = []
    for form in raw.split(","):
        form = form.strip()
        if not form:
            continue
        kind = kinds.get(base_term(form))
        if kind is None:
            out.append(form)          # unlabelled rather than guessed at
            continue
        out.append(f"{form} ({ARTICLE.get(kind[0], 'a')} {kind})")
    return ", ".join(out)


def classify(model):
    """Label each term in the cache once, and write the YAML.

    Eleven terms. The model is asked with no context at all, which is the
    honest version of what the app could do offline — and it is small enough
    to check by hand, so a wrong label is the author's, not the model's.
    """
    cases = json.loads(CACHE.read_text())
    terms = sorted({base_term(f) for c in cases for f in c["terms"].split(",") if f.strip()})
    system = ("You label a word with what kind of thing it names. Answer with exactly "
              "one of these words and nothing else: " + ", ".join(CLASSES) + ".")
    lines = []
    for term in terms:
        payload = {
            "model": model, "stream": False, "think": False,
            "options": {"temperature": 0, "num_predict": 8},
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": f"{term}\n\nWhat kind of thing is it?"}],
        }
        request = urllib.request.Request(
            ENDPOINT, data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=60) as response:
            reply = json.loads(response.read())["message"]["content"].strip().lower()
        kind = next((c for c in CLASSES if c in reply), "")
        print(f"  {term:<12} {model}: {reply!r:<14} -> {kind or 'UNPARSED'}")
        lines.append(f"  {term}: {kind}")
    print(f"\n{len(terms)} terms. Check every one by hand before using it.")
    return lines


# ── the run ──────────────────────────────────────────────────────────────────

def reachable(cases):
    """The menus that held the true sentence, and what the rest cost.

    A prompt cannot be blamed for an option that was never on the list, and
    counting those in hides every difference behind a constant.
    """
    keep = [c for c in cases
            if recall.normalise(c["said"]) in [recall.normalise(o) for o in c["menu"]]]
    return keep, len(cases) - len(keep)


def run(cases, framing, model, kinds):
    """One framing over every reachable menu. Returns wav -> (right, chosen)."""
    system = build(framing)
    style = FRAMINGS[framing]["terms"]
    out = {}
    for case in cases:
        terms = render_terms(case["terms"], style, kinds)
        chosen = tune.ask(model, system.replace("{terms}", terms), case["menu"],
                          case.get("scores") or "")
        right = chosen is not None and recall.normalise(chosen) == recall.normalise(case["said"])
        out[case["wav"]] = (right, chosen)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--framing", default="all",
                    help="comma-separated framing names, or 'all'")
    ap.add_argument("--model", default=os.environ.get("PARROTFLOW_JUDGE_MODEL", "gemma4:e4b"))
    ap.add_argument("--classify", action="store_true",
                    help="label the vocabulary terms with gemma4:e4b and stop")
    ap.add_argument("--json", metavar="PATH", help="write per-case results here")
    ap.add_argument("--list", action="store_true", help="print the framings and stop")
    args = ap.parse_args()

    if args.list:
        for name, frame in FRAMINGS.items():
            print(f"  {name:<16} {frame['doc']}")
        return 0
    if not CACHE.exists():
        print("✗ no cache — run scripts/tune-judge.py --harvest first")
        return 2
    if args.classify:
        for line in classify(args.model):
            print(line)
        return 0

    names = (list(FRAMINGS) if args.framing == "all"
             else [n.strip() for n in args.framing.split(",") if n.strip()])
    for name in names:
        if name not in FRAMINGS:
            print(f"✗ no framing {name!r}; --list shows them all")
            return 2
    kinds = load_kinds() if any(FRAMINGS[n]["terms"] == "typed" for n in names) else {}

    cases, unreachable = reachable(json.loads(CACHE.read_text()))
    chance = sum(1 / len(c["menu"]) for c in cases)
    print(f"\n  {len(cases)} reachable menus, {unreachable} never held the answer."
          f"  Judge {args.model}, temperature 0.")
    print(f"  Chance is {chance:.1f}/{len(cases)} — half these menus hold two options (F13).")
    print(f"  The same {len(cases)} cases are tuned on and reported on."
          " There is no held-out set.\n")

    results = {}
    for name in names:
        before = len(tune.STRAY)
        results[name] = run(cases, name, args.model, kinds)
        picked = sum(right for right, _ in results[name].values())
        stray = len(tune.STRAY) - before
        note = f"   {stray} reply(s) had no bare letter" if stray else ""
        print(f"  {name:<16} picked {picked:>2}/{len(cases)}"
              f"   (chance {chance:.1f}){note}")

    control = names[0]
    if len(names) > 1:
        print(f"\n  per case, against {control!r} — + won, - lost\n")
        for name in names[1:]:
            won = [c["wav"][22:-4] for c in cases
                   if results[name][c["wav"]][0] and not results[control][c["wav"]][0]]
            lost = [c["wav"][22:-4] for c in cases
                    if results[control][c["wav"]][0] and not results[name][c["wav"]][0]]
            print(f"  {name:<16} +{len(won)} {' '.join(won) or '-'}")
            print(f"  {'':<16} -{len(lost)} {' '.join(lost) or '-'}")

    print(f"\n  the ordinary-word collision class — {len(COLLISIONS)} clips PR #68 recorded\n")
    print("  " + f"{'clip':<10}{'what collided':<44}"
          + "".join(f"{n[:9]:<10}" for n in names))
    # The stamp is the clip's time, which is what every finding cites. A clip
    # that never held its true sentence is not in `cases` at all, and saying so
    # is the point: it cannot be scored by any framing.
    at_stamp = {c["wav"][22:-4]: c["wav"] for c in cases}
    for stamp, what in COLLISIONS.items():
        wav = at_stamp.get(stamp)
        marks = ("unreachable — never on the menu" if wav is None else
                 "".join(f"{'   ✓' if results[n][wav][0] else '   ✗':<10}" for n in names))
        print(f"  {stamp:<10}{what:<44}{marks}")
    scored = [at_stamp[s] for s in COLLISIONS if s in at_stamp]
    print()
    for name in names:
        got = sum(results[name][wav][0] for wav in scored)
        print(f"  {name:<16} {got}/{len(scored)} of the collision class")

    if args.json:
        Path(args.json).write_text(json.dumps(
            {n: {w: {"right": r, "chose": c} for w, (r, c) in res.items()}
             for n, res in results.items()}, indent=1, ensure_ascii=False))
        print(f"\n  per-case results written to {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
