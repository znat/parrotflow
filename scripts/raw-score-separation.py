#!/usr/bin/env python3
"""With the vocabulary bonus at zero, does the raw score know a term was said?

    scripts/raw-score-separation.py                     # report from the cache
    scripts/raw-score-separation.py --sweep DIR         # replay the clips
    scripts/raw-score-separation.py --build DIR         # dumps -> cache
    scripts/raw-score-separation.py --table FILE        # per-proposal table

Three groups, over every proposal the pass makes on the 145 clips of
`tests/menu-cases.yaml`:

    A   the term was said       the label puts the term at this span
    B   the term was NOT said   the label puts an ordinary word there
    C   random terms            every other term the spotter scored over the
                                same span, restricted to terms that appear
                                nowhere in the label — so definitely absent

The statistic has to be one number on one scale for all three. It is the
**spotter's score for the term over the span**, in nats per token. Group C
has no decoded-word score to subtract, because nothing ever proposed those
terms, so a gap cannot be formed for them. The rescorer's gap — raw term
minus raw decoded word, the number the judge is shown — is reported beside
it, for the two groups that have one.

The two scores are the same dynamic program, `CtcDPAlgorithm`, normalised by
the term's token count. `ctcWordSpotConstrained` scores a term over a window
the rescorer chooses; `ctcWordSpotMultiple` finds its own. Same units, not
the same window, and that is the one seam in the comparison.

**No model call anywhere.** No judge, no Ollama, no menu. The sweep runs with
a scratch `PARROTFLOW_CONFIG_DIR` whose pipeline has no `vocabulary:` stage.

Replay scores are nondeterministic (F12a), so every clip is replayed three
times and each proposal carries the median of the runs it appeared in. The
report says how far a proposal moved between runs.
"""
import argparse
import difflib
import json
import os
import re
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CASES = ROOT / "tests/menu-cases.yaml"
CACHE = ROOT / "tests/raw-score-separation.json"
CLIPS = Path.home() / "Recordings/ParrotFlow Dev"
_BUILT = ROOT / ".build/ParrotFlowDev.app/Contents/MacOS/ParrotFlow"
APP = str(_BUILT) if _BUILT.exists() else \
    "/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow"

CONDITIONS = ("cbw0", "base")
RUNS = (1, 2, 3)


# ---------------------------------------------------------------- ground truth

def load_cases():
    """`wav` and `said`, the two fields scripts/menu-recall.py reads."""
    cases, wav, said = {}, None, None
    for line in CASES.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("- wav:"):
            if wav:
                cases[wav] = said
            wav, said = stripped.split(":", 1)[1].strip(), None
        elif stripped.startswith("said:"):
            body = stripped.split(":", 1)[1].split("#")[0].strip()
            said = body.strip('"') or None
        elif said is not None and stripped and not stripped.startswith("#"):
            said = said + " " + stripped.strip('"')
    if wav:
        cases[wav] = said
    return cases


def norm(word):
    return re.sub(r"[^\w']", "", word or "").lower()


def stem(word):
    """A term and its possessive or plural are the same name."""
    w = norm(word)
    for suffix in ("'s", "s'", "s"):
        if len(w) > 3 and w.endswith(suffix):
            return w[: -len(suffix)]
    return w


def label_span(words, said, first, last, term):
    """A, B or unclear for one proposal. The rule, in full.

    Align the decoder's words to the label's words with difflib. The proposal
    covers decoded words `first..last`.

    * every covered word in an `equal` block — the label keeps what the
      decoder wrote, so the speaker said the ordinary word: **B**.
    * covered words in a `replace` block — look only at the label words that
      block puts at that position. **A term somewhere else in the sentence is
      not the same as a term belonging at this span.** The term in the aligned
      window: **A**. The term nowhere in the block: **B**. The term in the
      block but not at this position, and the block too long to pin it:
      unclear.
    * a `delete` block, or no label at all: unclear.
    """
    if said is None or first is None:
        return "unclear", "no label or no span"
    decoded = [norm(w) for w in words]
    truth = [norm(w) for w in said.split()]
    if not decoded or not truth:
        return "unclear", "empty"
    ops = difflib.SequenceMatcher(a=decoded, b=truth, autojunk=False).get_opcodes()
    target = stem(term)

    verdicts, reasons = set(), []
    for index in range(first, last + 1):
        block = next((o for o in ops if o[1] <= index < o[2]), None)
        if block is None:
            verdicts.add("unclear")
            reasons.append("no block")
            continue
        tag, a0, a1, b0, b1 = block
        if tag == "equal":
            verdicts.add("B")
            reasons.append("the label keeps the decoded word")
        elif tag == "replace":
            here = [stem(t) for t in truth[b0:b1]]
            if target not in here:
                verdicts.add("B")
                reasons.append("the term is absent from the replaced region")
            elif (a1 - a0) <= 3 and (b1 - b0) <= 3:
                verdicts.add("A")
                reasons.append("the term is what the label puts here")
            else:
                share = (index - a0) / (a1 - a0 - 1) if a1 - a0 > 1 else 0.0
                middle = b0 + round(share * max(0, b1 - b0 - 1))
                window = [stem(t) for t in truth[max(b0, middle - 1):min(b1, middle + 2)]]
                if target in window:
                    verdicts.add("A")
                    reasons.append("the term is at the aligned position of a long block")
                else:
                    verdicts.add("unclear")
                    reasons.append("the term is in the block but not at this position")
        elif tag == "delete":
            verdicts.add("unclear")
            reasons.append("the decoded word has no counterpart")
        else:
            verdicts.add("unclear")
            reasons.append(tag)

    if verdicts == {"A"} or ("A" in verdicts and "unclear" not in verdicts):
        return "A", reasons[0]
    if verdicts == {"B"}:
        return "B", reasons[0]
    return "unclear", "; ".join(sorted(set(reasons)))


# ---------------------------------------------------------------- the sweep

def sweep(directory, config):
    """Replay every clip, both conditions, three runs. Writes the dumps.

    `--config` is a scratch `PARROTFLOW_CONFIG_DIR`: the live config with the
    `vocabulary:` stage deleted. Never the user's own directory.
    """
    if not Path(APP).exists():
        print(f"✗ {APP} not found — run `make app` first")
        return 2
    if not config:
        print("✗ --sweep needs --config <scratch PARROTFLOW_CONFIG_DIR>")
        return 2
    clips = list(load_cases())
    for index, wav in enumerate(clips, 1):
        for condition in CONDITIONS:
            for run in RUNS:
                out = Path(directory) / condition / str(run)
                out.mkdir(parents=True, exist_ok=True)
                environment = dict(os.environ)
                environment["PARROTFLOW_CONFIG_DIR"] = config
                environment["PARROTFLOW_SPOTTER_DUMP"] = "1"
                if condition == "cbw0":
                    environment["PARROTFLOW_CBW"] = "0"
                else:
                    environment.pop("PARROTFLOW_CBW", None)
                done = subprocess.run(
                    [APP, "--transcribe", str(CLIPS / wav)],
                    capture_output=True, text=True, env=environment, timeout=300,
                )
                blob = done.stdout + done.stderr
                kept = [re.sub(r"^.*\[ParrotFlow\] ", "", line)
                        for line in blob.splitlines()
                        if re.search(r"\[ParrotFlow\] (dump |  word |spotter: |vocabulary: )",
                                     line)]
                (out / f"{wav}.txt").write_text("\n".join(kept) + "\n")
        if index % 10 == 0:
            print(f"  {index}/{len(clips)}…")
    print("sweep complete")
    return 0


# ---------------------------------------------------------------- the dumps

PROPOSAL = re.compile(
    r'^dump proposal kind=(\S+) verdict=(\S+) words=(\S+) at=(\S+) '
    r'heard="(.*)" heard_score=(\S+) term="(.*)" term_score=(\S+) '
    r'gap=(\S+) bonus=(\S+)$'
)
SPOTTER = re.compile(r"^spotter: (\S+) (-?[\d.]+) at ([\d.]+)s-([\d.]+)s$")
WORD = re.compile(r"^  word (.*) ([\d.]+)-([\d.]+)$")
TERMS = ["Arexvy", "Claude", "Matthieu", "Mirza", "Ollama", "Praisy",
         "Redcrawl", "Redrock", "Supabase", "Tasmeen", "Vercel"]


def number(text):
    return None if text == "none" else float(text)


def read_dump(path):
    decoded, words, spots, proposals = None, [], [], []
    for line in path.read_text().splitlines():
        if line.startswith("dump decoded "):
            decoded = line[len("dump decoded "):]
        elif (m := WORD.match(line)):
            words.append(m.group(1))
        elif (m := SPOTTER.match(line)):
            spots.append((m.group(1), float(m.group(2)),
                          float(m.group(3)), float(m.group(4))))
        elif (m := PROPOSAL.match(line)):
            first, last = (m.group(3).split("-") if m.group(3) != "none"
                           else ("none", "none"))
            start, end = (m.group(4).split("-") if m.group(4) != "none"
                          else ("none", "none"))
            proposals.append({
                "kind": m.group(1), "verdict": m.group(2),
                "first": None if first == "none" else int(first),
                "last": None if last == "none" else int(last),
                "start": None if start == "none" else float(start),
                "end": None if end == "none" else float(end),
                "heard": m.group(5), "heard_score": number(m.group(6)),
                "term": m.group(7), "term_score": number(m.group(8)),
                "gap": number(m.group(9)), "bonus": number(m.group(10)),
            })
    return decoded, words, spots, proposals


def best_spot(spots, term, start, end):
    """The term's best spotter score over anything overlapping the span."""
    if start is None:
        return None
    hits = [s for t, s, a, b in spots if t == term and min(b, end) > max(a, start)]
    return max(hits) if hits else None


def build(directory):
    """Dumps to cache. One row per proposal per run, plus the floor."""
    cases = load_cases()
    rows, floor, counts = [], [], []
    for condition in CONDITIONS:
        for run in RUNS:
            here = Path(directory) / condition / str(run)
            tally = {"condition": condition, "run": run, "rescorer": 0,
                     "applied": 0, "proposed": 0, "dropped": 0,
                     "spotter": 0, "wider": 0, "total": 0}
            for path in sorted(here.glob("*.wav.txt")):
                wav = path.name[:-4]
                said = cases.get(wav)
                decoded, words, spots, proposals = read_dump(path)
                if decoded is None:
                    continue
                spoken = {stem(t) for t in TERMS
                          if said and stem(t) in {stem(w) for w in said.split()}}
                for p in proposals:
                    tally["total"] += 1
                    tally[p["kind"]] += 1
                    if p["kind"] == "rescorer":
                        tally[p["verdict"]] += 1
                    group, reason = label_span(words, said, p["first"], p["last"],
                                               p["term"])
                    p.pop("bonus")
                    rows.append({
                        "wav": wav, "condition": condition, "run": run,
                        "group": group, "reason": reason,
                        "spot": best_spot(spots, p["term"], p["start"], p["end"]),
                        **p,
                    })
                    if p["kind"] == "wider" or p["start"] is None:
                        continue
                    for other in TERMS:
                        if stem(other) == stem(p["term"]) or stem(other) in spoken:
                            continue
                        value = best_spot(spots, other, p["start"], p["end"])
                        if value is not None:
                            floor.append({
                                "wav": wav, "condition": condition, "run": run,
                                "term": other, "spot": value,
                                "first": p["first"], "last": p["last"],
                            })
            counts.append(tally)
    # The floor is 6,000 rows before the runs are folded together and it is
    # never read per run, so it is stored as one median per span and term.
    folded = []
    for condition in CONDITIONS:
        folded += unique([f for f in floor if f["condition"] == condition],
                         SPAN, "spot")
    for row in folded:
        row.pop("run", None)
        row.pop("runs", None)
    # Columnar. The same twenty key names repeated 1,600 times is most of the
    # file, and this is a cache rather than something anyone reads.
    CACHE.write_text(json.dumps({
        "proposals": pack(rows),
        "floor": pack(folded),
        "counts": counts,
    }))
    print(f"wrote {CACHE}  ({len(rows)} proposal rows, {len(folded)} floor rows)")
    return 0


def pack(rows):
    columns = sorted({key for row in rows for key in row})
    return {"columns": columns,
            "rows": [[row.get(c) for c in columns] for row in rows]}


def unpack(block):
    return [dict(zip(block["columns"], row)) for row in block["rows"]]


# ---------------------------------------------------------------- statistics

def unique(rows, key, field):
    """One value per thing, the median of the runs it appeared in.

    Three runs produce the same proposal three times. Counting it three times
    inflates every n and makes replay noise look like data.
    """
    seen = {}
    for row in rows:
        if row.get(field) is None:
            continue
        seen.setdefault(key(row), []).append(row)
    out = []
    for group in seen.values():
        head = dict(group[0])
        head[field] = statistics.median(r[field] for r in group)
        head["runs"] = len(group)
        out.append(head)
    return out


def quantile(values, q):
    if not values:
        return float("nan")
    ordered = sorted(values)
    position = q * (len(ordered) - 1)
    low = int(position)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (position - low)


def describe(name, values):
    if not values:
        return f"  {name:<26} n=0"
    return ("  {:<26} n={:<5} min {:>7.2f}  q1 {:>7.2f}  med {:>7.2f}  "
            "q3 {:>7.2f}  max {:>7.2f}".format(
                name, len(values), min(values), quantile(values, .25),
                statistics.median(values), quantile(values, .75), max(values)))


def auc(positive, negative):
    """P(a random positive scores above a random negative). Ties count half."""
    if not positive or not negative:
        return float("nan")
    wins = 0.0
    for p in positive:
        for n in negative:
            wins += 1.0 if p > n else (0.5 if p == n else 0.0)
    return wins / (len(positive) * len(negative))


def inside(values, reference):
    """Share of `values` inside the closed range of `reference`."""
    if not values or not reference:
        return float("nan")
    low, high = min(reference), max(reference)
    return sum(1 for v in values if low <= v <= high) / len(values)


def histogram(name, values, low=-15.0, high=-2.0, step=1.0):
    if not values:
        print(f"  {name}: empty")
        return
    print(f"  {name}  (n={len(values)})")
    widest = max((sum(1 for v in values if e <= v < e + step)
                  for e in [low + i * step for i in range(int((high - low) / step))]),
                 default=1) or 1
    edge = low
    while edge < high - 1e-9:
        count = sum(1 for v in values if edge <= v < edge + step)
        bar = "#" * round(40 * count / widest)
        print(f"    {edge:>6.1f} {count:>5} {bar}")
        edge += step
    print(f"    below {low}: {sum(1 for v in values if v < low)}"
          f"   at or above {high}: {sum(1 for v in values if v >= high)}")


SPAN = lambda r: (r["wav"], stem(r["term"]), r["first"], r["last"])


def report(cache):
    rows, floors, counts = cache["proposals"], cache["floor"], cache["counts"]

    print("\n=== proposals per run ===")
    print(f"  {'condition':<9} {'run':<4} {'rescorer':>9} {'applied':>8} "
          f"{'proposed':>9} {'dropped':>8} {'spotter':>8} {'wider':>7} {'total':>7}")
    for t in counts:
        print(f"  {t['condition']:<9} {t['run']:<4} {t['rescorer']:>9} "
              f"{t['applied']:>8} {t['proposed']:>9} {t['dropped']:>8} "
              f"{t['spotter']:>8} {t['wider']:>7} {t['total']:>7}")

    for condition in CONDITIONS:
        print(f"\n\n################  {condition}  ################")
        raw = [r for r in rows if r["condition"] == condition and r["kind"] != "wider"]
        scored = unique(raw, lambda r: SPAN(r) + (r["kind"],), "spot")
        floor = unique([f for f in floors if f["condition"] == condition], SPAN, "spot")
        gapped = unique([r for r in raw if r["kind"] == "rescorer"], SPAN, "gap")

        print(f"\n  {len(scored)} distinct scored proposals over "
              f"{len({r['wav'] for r in scored})} clips")
        print("\n=== how the labelling fell ===")
        for group in ("A", "B", "unclear"):
            n = sum(1 for r in scored if r["group"] == group)
            print(f"  {group:<8} {n:>4}   ({n / max(1, len(scored)) * 100:.0f}%)")

        C = [f["spot"] for f in floor]
        for kind in ("all", "rescorer", "spotter"):
            here = scored if kind == "all" else [r for r in scored if r["kind"] == kind]
            A = [r["spot"] for r in here if r["group"] == "A"]
            B = [r["spot"] for r in here if r["group"] == "B"]
            print(f"\n=== raw spotter score at the span — {kind} proposals "
                  f"(nats per token) ===")
            print(describe("A  term was said", A))
            print(describe("B  term was NOT said", B))
            print(describe("C  random terms", C))
            print(f"\n  AUC(A vs B) = {auc(A, B):.3f}     AUC(A vs C) = {auc(A, C):.3f}"
                  f"     AUC(B vs C) = {auc(B, C):.3f}")
            print(f"  B inside A's range: {inside(B, A) * 100:.0f}%"
                  f"     B inside C's range: {inside(B, C) * 100:.0f}%"
                  f"     A inside C's range: {inside(A, C) * 100:.0f}%")
            if kind == "all":
                print()
                histogram("A", A)
                histogram("B", B)
                histogram("C", C)

        # ---- would moving `spotterFloor` cut the failures?
        #
        # The spotter path is where most failures come from and it carries no
        # gap, so the AUCs on the gap never saw it. Its own score is the only
        # number it has, and `Vocabulary.spotterFloor` is the only place that
        # number is already used as a gate. This is what moving it would buy.
        #
        # Only floors at or above today's -5.0 can be read off these runs. A
        # lower floor admits spans this sweep never scored, because
        # `acousticSpans` dropped them before anything logged a proposal.
        spot_rows = [r for r in scored if r["kind"] == "spotter"]
        print("\n=== moving spotterFloor — spotter-path proposals only ===")
        print(f"  A n={sum(1 for r in spot_rows if r['group'] == 'A')}   "
              f"B n={sum(1 for r in spot_rows if r['group'] == 'B')}   "
              f"(today's floor is -5.0; below it these runs have no data)")
        print(f"  {'floor':>7} {'A kept':>8} {'B kept':>8} {'B cut':>7} {'A cut':>7}")
        cut = -5.0
        while cut <= -3.0 + 1e-9:
            A = [r for r in spot_rows if r["group"] == "A"]
            B = [r for r in spot_rows if r["group"] == "B"]
            keptA = sum(1 for r in A if r["spot"] >= cut)
            keptB = sum(1 for r in B if r["spot"] >= cut)
            print(f"  {cut:>7.2f} {keptA:>4}/{len(A):<3} {keptB:>4}/{len(B):<3} "
                  f"{len(B) - keptB:>7} {len(A) - keptA:>7}")
            cut += 0.25

        # ---- the rescorer's own term score, per token, instead of the gap
        #
        # `spot` and the gap are not the same quantity. Both CTC scores are
        # normalised by the term's token count, but the gap subtracts a
        # decoded-word score normalised by a different token count, so the
        # normalisation could be doing the work. This asks the rescorer's raw
        # term score on its own, which is per token and needs no subtraction.
        termed = unique([r for r in raw if r["kind"] == "rescorer"],
                        SPAN, "term_score")
        tA = [r["term_score"] for r in termed if r["group"] == "A"]
        tB = [r["term_score"] for r in termed if r["group"] == "B"]
        print("\n=== the rescorer's raw term score, per token, not the gap ===")
        print(describe("A  term was said", tA))
        print(describe("B  term was NOT said", tB))
        print(f"\n  AUC(A vs B) = {auc(tA, tB):.3f}     AUC(A vs C) = {auc(tA, C):.3f}"
              f"     AUC(B vs C) = {auc(tB, C):.3f}")
        print(f"  B inside A's range: {inside(tB, tA) * 100:.0f}%")

        print("\n=== the same name only, A and B against C ===")
        for label, group in (("A", "A"), ("B", "B")):
            pairs = wins = 0.0
            for term in TERMS:
                x = [r["spot"] for r in scored
                     if r["group"] == group and stem(r["term"]) == stem(term)]
                c = [f["spot"] for f in floor if stem(f["term"]) == stem(term)]
                if x and c:
                    wins += auc(x, c) * len(x) * len(c)
                    pairs += len(x) * len(c)
            print(f"  AUC({label} vs C), matched by term = "
                  f"{wins / pairs if pairs else float('nan'):.3f}")

        gA = [r["gap"] for r in gapped if r["group"] == "A"]
        gB = [r["gap"] for r in gapped if r["group"] == "B"]
        print("\n=== rescorer gap — raw term minus raw decoded word (nats) ===")
        print(describe("A  term was said", gA))
        print(describe("B  term was NOT said", gB))
        print(f"\n  AUC(A vs B) = {auc(gA, gB):.3f}"
              f"     B inside A's range: {inside(gB, gA) * 100:.0f}%")

        print("\n=== best single cut, fitted and scored on the same rows ===")
        for name, field, here in (("spotter score, all", "spot", scored),
                                  ("spotter score, rescorer", "spot",
                                   [r for r in scored if r["kind"] == "rescorer"]),
                                  ("rescorer gap", "gap", gapped)):
            pairs = [(r[field], r["group"]) for r in here if r["group"] in ("A", "B")]
            if not pairs:
                continue
            nA = sum(1 for _, g in pairs if g == "A")
            best = max(max(sum(1 for v, g in pairs if (v >= cut) == (g == "A"))
                           for cut, _ in pairs),
                       max(sum(1 for v, g in pairs if (v <= cut) == (g == "A"))
                           for cut, _ in pairs))
            constant = max(nA, len(pairs) - nA)
            print(f"  {name:<25} best cut {best}/{len(pairs)} "
                  f"({best / len(pairs) * 100:.0f}%)   the constant "
                  f"{constant}/{len(pairs)} ({constant / len(pairs) * 100:.0f}%)")

        print("\n=== per term, spotter score at the span ===")
        print(f"  {'term':<10} {'A n':>4} {'A med':>7} {'B n':>4} {'B med':>7} "
              f"{'C n':>5} {'C med':>7} {'AUC A/B':>8} {'AUC A/C':>8} {'AUC B/C':>8}")
        for term in TERMS:
            a = [r["spot"] for r in scored
                 if r["group"] == "A" and stem(r["term"]) == stem(term)]
            b = [r["spot"] for r in scored
                 if r["group"] == "B" and stem(r["term"]) == stem(term)]
            c = [f["spot"] for f in floor if stem(f["term"]) == stem(term)]
            med = lambda v: statistics.median(v) if v else float("nan")
            print(f"  {term:<10} {len(a):>4} {med(a):>7.2f} {len(b):>4} "
                  f"{med(b):>7.2f} {len(c):>5} {med(c):>7.2f} "
                  f"{auc(a, b):>8.2f} {auc(a, c):>8.2f} {auc(b, c):>8.2f}")

    print("\n\n=== run to run — the same proposal, three replays (F12a) ===")
    for condition in CONDITIONS:
        for field in ("gap", "spot", "term_score"):
            seen = {}
            for r in rows:
                if r["condition"] != condition or r["kind"] == "wider":
                    continue
                if r.get(field) is None:
                    continue
                seen.setdefault(SPAN(r), {})[r["run"]] = r[field]
            spreads = [max(v.values()) - min(v.values())
                       for v in seen.values() if len(v) == len(RUNS)]
            if not spreads:
                continue
            print(f"  {condition:<6} {field:<11} n={len(spreads):<4} "
                  f"median {statistics.median(spreads):>5.2f}   "
                  f"q3 {quantile(spreads, .75):>5.2f}   max {max(spreads):>5.2f}   "
                  f"over 1 nat {sum(1 for s in spreads if s > 1) / len(spreads) * 100:.0f}%")
        present = {}
        for r in rows:
            if r["condition"] != condition or r["kind"] == "wider":
                continue
            present.setdefault(SPAN(r), set()).add(r["run"])
        stable = sum(1 for v in present.values() if len(v) == len(RUNS))
        print(f"  {condition:<6} {'presence':<11} {stable}/{len(present)} "
              f"proposals appeared in all three runs")
    return 0


def table(cache, path):
    """Every A and B proposal, one line each. Long, so it lives on its own."""
    lines = ["# Every proposal, with the label that decided its group",
             "",
             "Produced by `scripts/raw-score-separation.py --table`. Read the",
             "round in [judge-framings.md](judge-framings.md) first — this file",
             "is the evidence under it, not an argument.",
             "",
             "`spot` is the spotter's raw score for the term over the span, in",
             "nats per token. `gap` is the rescorer's raw term score minus the",
             "raw decoded-word score; blank where the pass never scored the",
             "decoded word. Every number is the median of the three replays the",
             "proposal appeared in.",
             ""]
    rows = cache["proposals"]
    cases = load_cases()
    for condition in CONDITIONS:
        raw = [r for r in rows if r["condition"] == condition and r["kind"] != "wider"]
        scored = unique(raw, lambda r: SPAN(r) + (r["kind"],), "spot")
        gaps = {SPAN(r) + (r["kind"],): r["gap"]
                for r in unique(raw, lambda r: SPAN(r) + (r["kind"],), "gap")}
        lines += [f"## {condition}", "",
                  "| clip | group | kind | heard | term | spot | gap | said |",
                  "|---|---|---|---|---|---|---|---|"]
        for r in sorted(scored, key=lambda r: (r["group"], r["wav"], r["first"])):
            gap = gaps.get(SPAN(r) + (r["kind"],))
            said = (cases.get(r["wav"]) or "").replace("|", "/")
            said = said if len(said) < 90 else said[:87] + "…"
            lines.append(
                f"| {r['wav'].replace('parrotflow-2026-08-', '').replace('.wav', '')} "
                f"| {r['group']} | {r['kind']}/{r['verdict']} "
                f"| {r['heard'].replace('|', '/')} | {r['term']} "
                f"| {r['spot']:.2f} | {'' if gap is None else f'{gap:.2f}'} "
                f"| {said} |")
        lines.append("")
    Path(path).write_text("\n".join(lines) + "\n")
    print(f"wrote {path}")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sweep", metavar="DIR", help="replay the clips into DIR")
    ap.add_argument("--config", metavar="DIR",
                    help="scratch PARROTFLOW_CONFIG_DIR for --sweep")
    ap.add_argument("--build", metavar="DIR", help="turn DIR's dumps into the cache")
    ap.add_argument("--table", metavar="FILE", help="write the per-proposal table")
    args = ap.parse_args()

    if args.sweep:
        return sweep(args.sweep, args.config)
    if args.build:
        return build(args.build)
    if not CACHE.exists():
        print(f"✗ no cache at {CACHE} — run --sweep then --build")
        return 2
    cache = json.loads(CACHE.read_text())
    cache["proposals"] = unpack(cache["proposals"])
    cache["floor"] = unpack(cache["floor"])
    if args.table:
        return table(cache, args.table)
    return report(cache)


if __name__ == "__main__":
    sys.exit(main())
