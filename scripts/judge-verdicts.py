#!/usr/bin/env python3
"""Score the judge on substitutions, with both blind controls beside it.

    scripts/judge-verdicts.py --runs 3
    scripts/judge-verdicts.py --arm verdict --verbose
    scripts/judge-verdicts.py --menus            # the older cached menus too

`tune-judge.py` scores the retired lettered menu. This scores the question the
app asks now: the sentence the recogniser wrote, the same sentence after the
vocabulary pass, and one KEEP or REVERT per substitution.

Five arms, and the last two are the point:

    shipped   the retired menu prompt, built as the menu it expects
    verdict   the per-change prompt, without naming the vocabulary
    named     the per-change prompt as the app compiles it in
    keep      no model — every substitution stands. This is the stage switched
              off: the transcript that arrives is the transcript that ships.
    revert    no model — every substitution goes. This is the vocabulary rules
              switched off.

Part 1 §2 of the plan: a mechanism that does not beat its own blind version has
not been shown to work. There are two blind versions here because the set is
not balanced — 22 of the 74 substitutions are names the speaker really said —
and an arm that beats only one of them has beaten nothing.

## The cases

`tests/judge-verdicts.json`, 61 clips and 74 substitutions from one speaker's
2026-08-10 session. Every clip is a reading of a scripted line, half of them
built to collide: `general` against `Redcrawl`, `praise` against `Praisy`,
`bedrock` against `Redrock`, `Versailles` against `Vercel`.

`after` is `heard` with every substitution taken, built the same way whatever
the judge did on the day. That matters — an earlier extraction read `after` off
the final transcript, so the eight clips the judge reverted had no `after` at
all and fell out of the set. Seven of those eight are clips the retired prompt
gets right, so leaving them out flattered every new arm.

**One row is ill-posed and is marked `hard`.** On `09-35-54` the speaker said
"That is a Redcrawl problem, not a Redrock one" and the pass wrote `Redrock`
over "retroll", where they said Redcrawl. Neither verdict recovers that
sentence. It is labelled REVERT — the name written is not the name said — and
kept rather than dropped, because dropping a row nobody can win is how a case
set gets easy.

## The split

`TUNED_ON` is the nineteen clips the wording was first read on. The held-out
column is everything else, and it is the only number worth quoting for a
wording that was chosen here.
"""
import argparse
import json
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CASES = ROOT / "tests/judge-verdicts.json"
MENUS = ROOT / "tests/judge-menus.json"
RETIRED = ROOT / "tests/fixtures/retired-menu-prompt.md"
LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

TUNED_ON = {
    "09-32-49", "09-33-12", "09-33-26", "09-33-37", "09-34-02", "09-34-34",
    "09-35-40", "09-35-54", "09-35-59", "09-36-04", "09-36-15", "09-36-29",
    "09-37-11", "09-38-18", "09-38-28", "09-38-33", "09-41-48", "09-42-02",
    "09-42-09",
}

# The prompt the app compiles in, copied rather than read: the app is a bundle
# and this cannot link it. `scripts/check-judge-prompt.sh` fails when the two
# stop matching, so a harness can never quietly score a prompt nobody ships.
PROMPT = """The user dictates text. A deterministic pass has already replaced some words
with names from their vocabulary.

That pass matches spelling only. It never hears the sentence. It fires on every
occurrence of a spelling it knows, including the ones where the user meant the
ordinary word.

Below is the sentence as the recogniser wrote it, and the same sentence after
the pass. For each replacement, say whether it should stand.

A replacement stands when that name makes sense where it sits. Revert it when
the original was the ordinary word and the name does not belong in that
sentence.

Sometimes the user is teaching a correction rather than dictating — "urza
spells mirza", "Versal spells V E R C E L". The word before "spells" has to
survive. Keep those.

The names in their vocabulary are: {terms}. Anything else in the sentence is an
ordinary word, however much it looks like one of them.

Example.

  heard:   add a little sage to the sauce and let it rest
  after:   add a little Sage to the sauce and let it rest
  changed: 1. sage -> Sage

  The sentence is about cooking. An accounting system does not go in a sauce.
  1. REVERT

  heard:   the invoice is still sitting in sage
  after:   the invoice is still sitting in Sage
  changed: 1. sage -> Sage

  An invoice sitting in the accounting system is what the sentence is about.
  1. KEEP"""

# The vocabulary paragraph is the one wording change made after the first read,
# and it was chosen on the tuned split alone: 21 of 24 against 18. On the full
# set it is 62 against 59, and it wins where it was expected to — 22 of 22 on
# the substitutions that really were names, against 13.
WITHOUT_TERMS = re.sub(
    r"\nThe names in their vocabulary are.*?them\.\n", "", PROMPT, flags=re.S
)


def ask(system, user, model, endpoint, tokens):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user}],
        "stream": False, "think": False,
        "options": {"temperature": 0, "num_predict": tokens},
    }).encode()
    request = urllib.request.Request(
        endpoint + "/api/chat", data=body, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        return json.loads(response.read())["message"]["content"].strip()


# --- the retired menu, as an arm ---------------------------------------------

def menu(case):
    """Every reading the substitutions allow, the decoder's own first.

    The enumeration `VocabularyJudge.readings` used to do: the last place
    varies fastest, so the first combination is every place's first option,
    which is what the decoder wrote.
    """
    changes = case["changes"]
    sentences, combos = [], []
    for index in range(2 ** len(changes)):
        combination = [(index >> (len(changes) - 1 - n)) & 1 for n in range(len(changes))]
        text, cursor = "", 0
        for change, pick in zip(changes, combination):
            start, end = change["at"]
            text += case["after"][cursor:start]
            text += change["now"] if pick else change["was"]
            cursor = end
        text += case["after"][cursor:]
        if text not in sentences:
            sentences.append(text)
            combos.append(combination)
    return sentences, combos


def chosen(reply, count):
    """The letter the reply names, the way the retired parser read it.

    A bare letter wins over a letter inside a word, and `I` goes last because
    it is also an English word.
    """
    upper = reply.upper()
    words = re.split(r"[^A-Z'’]+", upper)
    named = [LETTERS.index(w) for w in words
             if len(w) == 1 and w in LETTERS and LETTERS.index(w) < count]
    for index in named:
        if LETTERS[index] != "I":
            return index
    if named:
        return named[0]
    for character in upper:
        if character in LETTERS and LETTERS.index(character) < count:
            return LETTERS.index(character)
    return None


def run_shipped(case, model, endpoint):
    sentences, combos = menu(case)
    terms = ", ".join(sorted({c["now"] for c in case["changes"]}))
    system = RETIRED.read_text().split("-->", 1)[-1].strip().replace("{terms}", terms)
    listed = "\n".join(f"{LETTERS[i]}. {s}" for i, s in enumerate(sentences))
    reply = ask(system, listed + "\n\nWhich letter?", model, endpoint, 8)
    pick = chosen(reply, len(sentences))
    # Fails closed the way the stage does: an unreadable reply keeps the text
    # that arrived, and the text that arrives already holds the names.
    combination = combos[pick] if pick is not None else [1] * len(case["changes"])
    return ["KEEP" if bit else "REVERT" for bit in combination], reply


# --- the shipped arm ----------------------------------------------------------

def run_verdict(case, model, endpoint, prompt=PROMPT):
    terms = ", ".join(sorted({c["now"].rstrip("'’s") for c in case["changes"]}))
    listed = "\n".join(
        f"{n}. {c['was']} -> {c['now']}" if n == 1
        else f"           {n}. {c['was']} -> {c['now']}"
        for n, c in enumerate(case["changes"], 1)
    )
    user = (f"Now this one.\n\n  heard:   {case['heard']}\n"
            f"  after:   {case['after']}\n  changed: {listed}\n\n"
            "Answer with one line per change: its number, then KEEP or REVERT."
            " Nothing else.")
    reply = ask(prompt.replace("{terms}", terms), user, model, endpoint,
                8 * len(case["changes"]) + 8)
    return parse(reply, len(case["changes"])), reply


def parse(reply, count):
    """One verdict per change. A port of `VocabularyJudge.verdicts`.

    Kept in step with the Swift on purpose, and `scripts/check-verdicts.sh`
    scores the Swift directly: a harness that reads a reply differently scores
    a decision the app never made.
    """
    read = [None] * count
    number = None
    for token in re.findall(r"\d+|[A-Za-z]+", reply.upper()):
        if token.isdigit():
            number = int(token) if len(token) < 18 else 0
            continue
        if token in ("KEEP", "REVERT"):
            at = (number if number is not None else (1 if count == 1 else 0)) - 1
            if 0 <= at < count and read[at] is None:
                read[at] = token
        number = None
    return [v or "KEEP" for v in read]


ARMS = {
    "shipped": run_shipped,
    "verdict": lambda case, m, e: run_verdict(case, m, e, WITHOUT_TERMS),
    "named": run_verdict,
    "keep": lambda case, *_: (["KEEP"] * len(case["changes"]), ""),
    "revert": lambda case, *_: (["REVERT"] * len(case["changes"]), ""),
}
MODEL_ARMS = ("shipped", "verdict", "named")


# --- the older cached menus ---------------------------------------------------

def from_menus():
    """The two-option menus of `tests/judge-menus.json`, as verdict cases.

    A verdict needs a before, an after and a list of changes, which a menu does
    not carry — so only the two-option menus reconcile: option A is what the
    decoder wrote, option B is the same sentence with the term in, and the diff
    between them is the one change. Wider menus are counted and left out,
    because working out which reading is "every substitution taken" from a
    deduplicated, trimmed menu is a guess.

    A menu whose `said` is neither option is unreachable and is excluded — the
    rule `tune-judge.py` uses. A prompt cannot be blamed for an answer that was
    never offered.
    """
    import difflib

    def normalise(text):
        return re.sub(r"[^a-z0-9 ]", "", text.lower()).strip()

    cases, wide, unreachable = [], 0, 0
    for entry in json.loads(MENUS.read_text()):
        if len(entry["menu"]) != 2:
            wide += 1
            continue
        before, after = entry["menu"]
        said = normalise(entry["said"])
        if said == normalise(before):
            truth = "REVERT"
        elif said == normalise(after):
            truth = "KEEP"
        else:
            unreachable += 1
            continue
        a, b = before.split(), after.split()
        ops = [o for o in difflib.SequenceMatcher(None, a, b).get_opcodes() if o[0] != "equal"]
        if len(ops) != 1:
            wide += 1
            continue
        _, i1, i2, j1, j2 = ops[0]
        at = len(" ".join(b[:j1])) + (1 if j1 else 0)
        now = " ".join(b[j1:j2])
        cases.append({
            "clip": entry["wav"][-12:-4], "heard": before, "after": after,
            "changes": [{"was": " ".join(a[i1:i2]), "now": now,
                         "at": [at, at + len(now)], "truth": truth}],
        })
    return cases, wide, unreachable


# --- scoring ------------------------------------------------------------------

def score(rows, held=None):
    def tally(wanted):
        rows_ = [r for r in rows if wanted(r)]
        return sum(1 for r in rows_ if r["got"] == r["truth"]), len(rows_)
    out = {
        "all": tally(lambda r: True),
        "keep": tally(lambda r: r["truth"] == "KEEP"),
        "revert": tally(lambda r: r["truth"] == "REVERT"),
    }
    if held:
        out["held"] = tally(lambda r: r["clip"] not in TUNED_ON)
        out["tuned"] = tally(lambda r: r["clip"] in TUNED_ON)
    return out


def play(cases, arms, runs, model, endpoint, verbose, split):
    results = {}
    for name in arms:
        runner = ARMS[name]
        per_run = []
        for run in range(runs if name in MODEL_ARMS else 1):
            rows = []
            for case in cases:
                verdicts, reply = runner(case, model, endpoint)
                for index, change in enumerate(case["changes"]):
                    rows.append({
                        "clip": case["clip"], "index": index,
                        "was": change["was"], "now": change["now"],
                        "truth": change["truth"], "got": verdicts[index],
                        "reply": reply,
                    })
            per_run.append(rows)
            print(f"  {name} run {run + 1}:"
                  f" {score(rows)['all'][0]}/{len(rows)}", file=sys.stderr)
        results[name] = per_run
        if verbose:
            for row in per_run[0]:
                if row["got"] != row["truth"]:
                    print(f"    {name} {row['clip']} {row['was']!r}->{row['now']!r}"
                          f" want {row['truth']} got {row['got']}", file=sys.stderr)

    columns = ["all", "keep", "revert"] + (["held", "tuned"] if split else [])
    heads = {"all": "all", "keep": "name was said", "revert": "name was not",
             "held": "held out", "tuned": "tuned on"}
    print()
    print("| arm | " + " | ".join(heads[c] for c in columns) + " | flips |")
    print("|" + "---|" * (len(columns) + 2))
    for name, per_run in results.items():
        first = score(per_run[0], held=split)
        flips = sum(
            1 for index in range(len(per_run[0]))
            if len({run[index]["got"] for run in per_run}) > 1
        ) if len(per_run) > 1 else 0
        cells = " | ".join(f"{first[c][0]}/{first[c][1]}" for c in columns)
        print(f"| `{name}` | {cells} | {flips} |")
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--arm", action="append", choices=list(ARMS))
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--model", default="gemma4:e4b-mlx")
    parser.add_argument("--endpoint", default="http://localhost:11434")
    parser.add_argument("--menus", action="store_true",
                        help="also score the two-option menus of tests/judge-menus.json")
    parser.add_argument("--out")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    arms = args.arm or list(ARMS)
    cases = json.loads(CASES.read_text())
    print(f"{len(cases)} clips, {sum(len(c['changes']) for c in cases)} substitutions"
          f" ({CASES.name})")
    results = play(cases, arms, args.runs, args.model, args.endpoint,
                   args.verbose, split=True)
    if args.out:
        pathlib.Path(args.out).write_text(json.dumps(results, indent=1))

    if args.menus:
        menus, wide, unreachable = from_menus()
        print()
        print(f"{len(menus)} two-option menus ({MENUS.name}); {wide} have more than"
              f" one place and are left out, {unreachable} never held the answer")
        play(menus, arms, args.runs, args.model, args.endpoint, args.verbose, split=False)


if __name__ == "__main__":
    main()
