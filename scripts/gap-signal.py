#!/usr/bin/env python3
"""Is the acoustic score block informative at menu time, or is it decoration?

    scripts/gap-signal.py              # every table
    scripts/gap-signal.py --spans      # one line per span, for reading by eye
    scripts/gap-signal.py --json out.json

**No model call anywhere in this file.** Every number is arithmetic over
`tests/judge-menus.json`, which is already on disk.

Three rounds of prompt work all failed the same way (F17, F18). The score block
is the main evidence the judge is handed, so this asks whether that evidence
carries any signal at all before another wording is tried.

Two observations motivate it. On clip `16-33-19` the two readings score
`"general" -9.88` and `"Redcrawl" -9.97`, while good matches elsewhere score
-0.32 and -2.28 — a 0.09 gap down at the floor may be noise rather than
similarity. And PR #68 measured every gap under 2.72, while the shipped
`decide_above: 3.0` is a threshold nothing in this cache reaches.

Four things are measured, per uncertain span rather than per case:

    the gap        does a larger |gap| predict that the acoustically preferred
                   reading is the one the speaker said?
    the base rate  how often is argmax right, against the constant policy
                   "always keep what the decoder wrote"?
    the floor      bucketed by the *better* of the two scores, not the gap.
                   The hypothesis is that everything below about -8 is
                   uninformative however large the gap.
    length         the scores are sums over token sequences of unequal length,
                   so they may not be comparable at all.

Nothing is fitted. The set is 53 cases and 77 spans; several buckets hold
fewer than ten spans and the tables say so. A rate over three spans is not a
finding.

The slot recovery — `reachable`, `analyse`, `slots`, `slot_pair`, `code_pick`,
`decoded_filler` — is round 2's `judge-routing.py` and is not rebuilt here. It
diffs the menu options against each other to find the spans the spotter was
unsure about, and refuses to run on a case whose slots do not rebuild the menu
exactly.
"""
import argparse
import json
import sys
from pathlib import Path
from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "tests/judge-menus.json"

routing = SourceFileLoader("routing", str(ROOT / "scripts/judge-routing.py")).load_module()

# The shipped setting the tables are read against. `decide_above:` is how many
# nats of raw margin the audio has to win by before the app decides without
# asking. See docs/transcription.md.
DECIDE_ABOVE = 3.0


def normalised(score, spelling):
    """Score per character of the spelling — the crude per-token stand-in.

    The scores in the cache have the vocabulary bonus **already taken out** by
    `Vocabulary.apply`, before `VocabularyJudge.scoreBlock` writes them. So the
    bonus is not recoverable from the cache and neither is the token count that
    `VocabularyRescorer.Config.adaptiveCbw` computes it from — that type lives
    in FluidAudio, not in this repository, and nothing here records its input.

    Character count is what is left. It is a stand-in and it is labelled as one
    everywhere it appears. It is monotone in token count for these spellings,
    which is the only property the comparison needs, but it is not the token
    count and no conclusion here rests on the exact value.
    """
    letters = max(len(routing.bare(spelling)), 1)
    return score / letters


def map_to_option(item, index, spelling):
    """The slot reading that holds a spelling, or None if it is ambiguous.

    Same rule as `routing.code_pick`: exact token first, then letters alone and
    case-folded. None is a real outcome, not an error — a merged span whose
    readings are `Praisy Mathieu's` and `Praisy's Mathieu's` holds `Praisy` in
    both, so the score block names a winner the slot cannot act on.
    """
    for fold in (False, True):
        key = routing.bare(spelling).lower() if fold else spelling
        hit = [o for o in item["options"][index]
               if key in {(routing.bare(t).lower() if fold else t) for t in o.split()}]
        if len(hit) == 1:
            return hit[0]
    return None


def collect(items):
    """One row per uncertain span. Scored and unscored spans both appear."""
    rows = []
    for item in items:
        for index, pair in enumerate(item["scored"]):
            decoded, truth = item["heard"][index], item["truth"][index]
            row = dict(clip=routing.stamp(item["case"]),
                       decoded=decoded, truth=truth,
                       keep=decoded == truth,
                       spans=len(item["spans"]),
                       options=item["options"][index],
                       scored=pair is not None)
            if pair is None:
                rows.append(row)
                continue
            heard, heard_score, term, term_score = pair
            # Closer to zero is clearer, so the preferred reading is the larger
            # (less negative) score. Ties go to the decoded spelling, which is
            # what `Vocabulary.autoApplies` does with `>`.
            raw_win = term if term_score > heard_score else heard
            norm_win = (term
                        if normalised(term_score, term) > normalised(heard_score, heard)
                        else heard)
            row.update(
                heard=heard, term=term,
                heard_score=heard_score, term_score=term_score,
                gap=abs(heard_score - term_score),
                best=max(heard_score, term_score),
                worst=min(heard_score, term_score),
                norm_gap=abs(normalised(heard_score, heard) - normalised(term_score, term)),
                argmax=map_to_option(item, index, raw_win),
                norm_argmax=map_to_option(item, index, norm_win),
                flipped=raw_win != norm_win,
                lengths=(len(routing.bare(heard)), len(routing.bare(term))))
            row["hit"] = row["argmax"] == truth
            row["norm_hit"] = row["norm_argmax"] == truth
            rows.append(row)
    return rows


def rate(rows, key):
    hit = sum(r[key] for r in rows)
    return f"{hit}/{len(rows)}", (hit / len(rows) if rows else 0.0)


def bucket_table(rows, key, edges, label, extra=()):
    """Hit rate per bucket, with the count always beside it."""
    print(f"\n  {label}\n")
    head = f"  {'bucket':<14}{'spans':<8}{'argmax right':<16}{'keep decoded':<16}"
    for name, _ in extra:
        head += f"{name:<18}"
    print(head)
    for low, high in zip(edges, edges[1:]):
        sub = [r for r in rows if low <= r[key] < high]
        if key == "best":
            name = (f"above {low:g}" if high >= 90 else
                    f"below {high:g}" if low <= -90 else f"{low:g} to {high:g}")
        else:
            name = f"{low:g} to {high:g}" if high < 90 else f"{low:g}+"
        line = (f"  {name:<14}{len(sub):<8}"
                f"{(rate(sub, 'hit')[0] if sub else '-'):<16}"
                f"{(rate(sub, 'keep')[0] if sub else '-'):<16}")
        for _, other in extra:
            line += f"{(rate(sub, other)[0] if sub else '-'):<18}"
        print(line)
        if 0 < len(sub) < 10:
            print(f"  {'':<14}{'':<8}(fewer than 10 spans — a count, not a rate)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spans", action="store_true", help="one line per span and stop")
    ap.add_argument("--json", metavar="PATH", help="write the per-span rows here")
    args = ap.parse_args()

    if not CACHE.exists():
        print("✗ no cache — run scripts/tune-judge.py --harvest first")
        return 2
    cases, unreachable = routing.reachable(json.loads(CACHE.read_text()))
    items = routing.analyse(cases)
    rows = collect(items)
    scored = [r for r in rows if r["scored"]]
    blank = [r for r in rows if not r["scored"]]

    print(f"\n  {len(cases)} reachable menus, {unreachable} never held the answer."
          f"  {len(rows)} uncertain spans.")
    print(f"  {len(scored)} spans carry a score line, {len(blank)} carry none.")
    print("  No model call anywhere in this file. The cache predates PR #70,"
          " so none of\n  the 15 live collisions of 2026-08-08 are in it.")

    gaps = sorted(r["gap"] for r in scored)
    print(f"\n  gaps run {gaps[0]:.2f} to {gaps[-1]:.2f} nats."
          f" {sum(g < 1 for g in gaps)}/{len(gaps)} are under 1 nat.")
    print(f"  {sum(g >= DECIDE_ABOVE for g in gaps)} of {len(gaps)} reach the shipped"
          f" decide_above of {DECIDE_ABOVE:g}.")

    # ── 1. the base rates ────────────────────────────────────────────────────
    # Two constants bound anything a predictor can claim. "Keep what the decoder
    # wrote" is the do-nothing policy; "always write the term" is its opposite.
    # A predictor that loses to a constant is worse than useless.
    undecidable = [r for r in scored if r["argmax"] is None]
    print("\n\n  ══ base rates, over the "
          f"{len(scored)} scored spans\n")
    print(f"  {'policy':<44}{'right':<12}")
    print(f"  {'argmax raw score':<44}{rate(scored, 'hit')[0]:<12}"
          f" ({rate(scored, 'hit')[1]:.0%})")
    print(f"  {'keep what the decoder wrote':<44}{rate(scored, 'keep')[0]:<12}"
          f" ({rate(scored, 'keep')[1]:.0%})")
    # Guessing a reading of one span at random. Not the case-level chance F13
    # reports, because this whole file counts spans.
    chance = sum(1 / len(r["options"]) for r in scored)
    always_term = sum(not r["keep"] for r in scored)
    print(f"  {'always write the vocabulary term':<44}"
          f"{f'{always_term}/{len(scored)}':<12} ({always_term / len(scored):.0%})")
    print(f"  {'guess a reading at random':<44}"
          f"{f'{chance:.1f}/{len(scored)}':<12} ({chance / len(scored):.0%})")
    print(f"\n  {len(undecidable)} of those spans name a winner the slot cannot act on —"
          "\n  a merged span whose readings all hold the same spelling. They are"
          "\n  counted as argmax misses. Over the "
          f"{len(scored) - len(undecidable)} spans argmax can decide it is "
          f"{sum(r['hit'] for r in scored)}/{len(scored) - len(undecidable)}.")
    print("\n  Over all 77 spans, including the 20 with no score line, keeping what the"
          f"\n  decoder wrote is right {sum(r['keep'] for r in rows)}/{len(rows)}.")

    # ── 2. does the gap predict correctness? ─────────────────────────────────
    # Buckets 2-4 and 4+ are merged into 2+. Nothing in the cache exceeds 2.72,
    # so splitting them would print two rows and one of them would be empty.
    bucket_table(scored, "gap", [0, 0.5, 1, 2, 90],
                 "by |gap| between the two readings — buckets 2-4 and 4+ merged,"
                 " nothing reaches 2.72")

    # ── 3. the absolute scores ───────────────────────────────────────────────
    # Bucketed by the better of the two, because that is how well the recogniser
    # understood the stretch of audio at all. A gap between two readings it
    # never understood is a gap between two guesses.
    bucket_table(scored, "best", [-90, -10, -8, -6, -4, 90],
                 "by the better of the two scores — how well the audio was heard at all")

    # The two together. If the score is trustworthy anywhere it is where the gap
    # is wide *and* the audio was heard clearly, so that quarter is printed on
    # its own rather than inferred from two one-dimensional tables.
    print("\n  the two together — is there a corner where the score can be trusted?\n")
    print(f"  {'':<30}{'spans':<8}{'argmax right':<16}{'keep decoded':<16}")
    for gap_name, gap_test in (("gap under 1", lambda r: r["gap"] < 1),
                               ("gap 1 or more", lambda r: r["gap"] >= 1)):
        for heard_name, heard_test in (("heard above -8", lambda r: r["best"] >= -8),
                                       ("heard below -8", lambda r: r["best"] < -8)):
            sub = [r for r in scored if gap_test(r) and heard_test(r)]
            print(f"  {f'{gap_name}, {heard_name}':<30}{len(sub):<8}"
                  f"{(rate(sub, 'hit')[0] if sub else '-'):<16}"
                  f"{(rate(sub, 'keep')[0] if sub else '-'):<16}")

    # ── 4. length ────────────────────────────────────────────────────────────
    differ = [r for r in scored if r["lengths"][0] != r["lengths"][1]]
    flipped = [r for r in scored if r["flipped"]]
    print("\n\n  ══ length. The cache does **not** carry the vocabulary bonus —"
          "\n  `Vocabulary.apply` subtracts it before `scoreBlock` writes the line, and"
          "\n  `VocabularyRescorer.Config` lives in FluidAudio, not in this repository."
          "\n  So the token count cannot be recovered by inverting `adaptiveCbw`."
          "\n  **Character count of the spelling is used as a crude stand-in.**\n")
    print(f"  {len(differ)} of {len(scored)} spans compare spellings of unequal length.")
    print(f"  Normalising flips the winner on {len(flipped)} spans.\n")
    print(f"  {'score used':<28}{'argmax right':<16}")
    print(f"  {'raw sum, as shipped':<28}{rate(scored, 'hit')[0]:<16}"
          f" ({rate(scored, 'hit')[1]:.0%})")
    print(f"  {'per character':<28}{rate(scored, 'norm_hit')[0]:<16}"
          f" ({rate(scored, 'norm_hit')[1]:.0%})")
    bucket_table(scored, "norm_gap", [0, 0.1, 0.25, 0.5, 90],
                 "by per-character |gap| — nats per character, not nats",
                 extra=[("per-char argmax", "norm_hit")])

    # ── 5. the spans with no score at all ────────────────────────────────────
    print(f"\n\n  ══ the {len(blank)} spans with no score line\n")
    print("  `scoreBlock` writes nothing for a proposal with no scores, and nothing"
          "\n  for a merged span that matches two lines. The judge sees the readings"
          "\n  and no evidence, and has to decide on the sentence alone.\n")
    print(f"  keep what the decoder wrote  {rate(blank, 'keep')[0]}"
          f" ({rate(blank, 'keep')[1]:.0%})")
    multi = [r for r in blank if r["spans"] > 1]
    print(f"  {len(multi)} of them sit in a case that holds more than one span.")

    if args.spans:
        print(f"\n\n  ══ every span\n")
        print(f"  {'clip':<10}{'gap':<7}{'best':<8}{'decoded':<20}{'true':<20}"
              f"{'argmax':<8}{'keep':<6}")
        for row in sorted(rows, key=lambda r: (not r["scored"], -r.get("gap", 0))):
            gap = f"{row['gap']:.2f}" if row["scored"] else "-"
            best = f"{row['best']:.2f}" if row["scored"] else "-"
            got = ("✓" if row["hit"] else "✗") if row["scored"] else "-"
            print(f"  {row['clip']:<10}{gap:<7}{best:<8}{row['decoded'][:19]:<20}"
                  f"{row['truth'][:19]:<20}{got:<8}"
                  f"{'✓' if row['keep'] else '✗':<6}")

    if args.json:
        Path(args.json).write_text(json.dumps(rows, indent=1, ensure_ascii=False))
        print(f"\n  per-span rows written to {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
