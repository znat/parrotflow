#!/usr/bin/env python3
"""Score vocabulary-proposal filters against the recorded corrections.

Reads `kind: edit` rows from a trace.jsonl, replays each through
`--edit-diff` to get the shipped `EditWatch.refusal` decision, and scores
three candidate additions: an age cap, a sentence-end guard, and phoneme
similarity as a second way in.

    python3 scripts/score-offers.py ~/Recordings/ParrotFlow\\ Dev/trace.jsonl
    python3 scripts/score-offers.py --first 86 ~/Recordings/...    # the PR table

`--first N` keeps the N earliest corrections. The trace keeps growing, and the
rows added while the pill was being tested by hand are not dictation, so a
number quoted anywhere has to name the set it came from.

MISHEARD is a hand label: which pairs are the decoder getting a word wrong
rather than the speaker changing their mind. Edit it before trusting any
number here. Counters -- the app wrote the term and he removed it -- are
dropped, not scored.
"""
import json, re, subprocess, sys

BINARY = "./.build/release/ParrotFlow"
# A MISHEARING: the decoder produced the wrong word for what was said. Not
# "is it a name" -- `boilerplate` and `pause` are dictionary words and both are
# mishearings. Keyed "heard|corrected", because direction matters.
MISHEARD = {
    "Mick|Mik", "Mik|Mick", "lectour|Lectoure", "Spacey|Spacy",
    "better stack|BetterStack", "this fluency|disfluency", "super base|Supabase",
    "data breaks|Databricks", "Praise|Praisy", "Ci|Cai", "s'\u00e9volue|c voulu",
    "projection|prediction", "these fluencies|disfluencies",
    "borderplay|boilerplate", "paralanguage|per_language",
    "Zelda Bricks|Databricks", "Si il|S'il", "meek|Mik", "DML|the ML",
    "this is|disease", "pass|pause", "edgy|ID", "when|Qwen", "coin|qwen",
    "trackage.|try catch",
}
# The app wrote the term and he took it out. `recordCounter` owns these; they
# are not proposals and do not belong in either column.
COUNTER = {"Supabase|SuperBase", "Qwen|When", "Qwen|when"}
ENDS = re.compile(r"[.?!]$")
MAX_AGE = 30   # EditWatch.window; the floor lives in EditWatch.soundFloor


def load(path):
    rows = []
    for line in open(path, encoding="utf-8", errors="replace"):
        if '"kind":"edit"' not in line:
            continue
        r = json.loads(line)
        text, (lo, hi) = r.get("text", ""), r.get("range", [0, 0])
        now = text[:lo] + r.get("corrected", "") + text[hi:]
        shown = subprocess.run(
            [BINARY, "--edit-diff", text, now, "--lang", r.get("lang", "en")],
            capture_output=True, text=True).stdout
        # The binary's own answer, so this scores what ships rather than a
        # re-implementation of it. The two branches are told apart by the
        # reason, which is the only place the sound rule announces itself.
        r["offered"] = "offer: yes" in shown            # after the change
        # The `words:` line, not the `offer:` one. `offer:` carries the age
        # and cut rules too, so reading the baseline off it moved the baseline
        # when the cut rule landed -- 22 offers became 20 with nothing changed.
        r["words_only"] = "words: yes" in shown
        r["phon"] = float(re.search(r"sound: ([\d.]+)", shown).group(1)) if "sound:" in shown else 0.0
        r["ends"] = bool(ENDS.search((r.get("heard") or "").strip()))
        # `offers` returns `.ended` only over an accept, so this line means
        # "would be offered but for the cut rule" -- which is what row 3 is.
        r["cut"] = "ends a sentence" in shown
        r["key"] = f'{r.get("heard", "")}|{r.get("corrected", "")}'
        if r["key"] not in COUNTER:
            rows.append(r)
    return rows


def main():
    args = sys.argv[1:]
    first = None
    if "--first" in args:
        i = args.index("--first")
        first = int(args[i + 1])
        del args[i:i + 2]
    rows = load(args[0])
    rows.sort(key=lambda r: r.get("at", ""))
    if first is not None:
        rows = rows[:first]
        print(f"first {len(rows)} corrections in time order, "
              f"through {rows[-1].get('at', '?')}\n")
    real = lambda r: r["key"] in MISHEARD
    young = lambda r: (r.get("after") or 0) <= MAX_AGE
    rules = [
        ("before: word lists only, any age", lambda r: r["words_only"]),
        (f"+ age <= {MAX_AGE}s", lambda r: r["words_only"] and young(r)),
        ("+ or it sounds like it", lambda r: (r["offered"] or r["cut"]) and young(r)),
        ("+ the heard side ends a sentence is out (shipped)",
         lambda r: r["offered"] and young(r)),
    ]
    for name, keep in rules:
        kept = [r for r in rows if keep(r)]
        good = sum(map(real, kept))
        total = sum(map(real, rows))
        print(f"{name:50} offers {len(kept):3}  {good:2} real  {len(kept) - good:2} noise"
              f"   precision {good / max(len(kept), 1):.0%}  recall {good / total:.0%}")
    print(f"\n{len(rows)} proposals, {sum(map(real, rows))} mishearings by hand label")


if __name__ == "__main__":
    main()
