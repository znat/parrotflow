#!/usr/bin/env python3
"""Score every reading on its own, instead of asking for one letter.

    scripts/rerank-judge.py                       # Qwen3-Reranker-0.6B
    scripts/rerank-judge.py --model mixedbread-ai/mxbai-rerank-base-v2
    scripts/rerank-judge.py --scores              # show it the acoustic numbers
    scripts/rerank-judge.py --fuse                # sweep the CTC weight
    scripts/rerank-judge.py --verbose             # list what it got wrong

The judge today reads a lettered list of up to sixteen near-identical sentences
and answers with one letter. That keeps the winner and throws away everything
else — no margin, no runner-up, no way to say "too close, ask the user".

A reranker is a cross-encoder: one question per candidate, answered `yes` or
`no`, scored by the gap between those two logits. The candidates never see each
other, so what comes back is a ranking with distances, not a vote.

Runs off `tests/judge-menus.json`, so no decoding and no app build. Needs the
MLX environment: `uv venv .venv-rerank && uv pip install mlx-lm`.

Three numbers are reported, and the second matters as much as the first:

    top-1   the true sentence ranked first
    top-3   it reached the top three — what a two-stage design would get
    margin  how far ahead the wrong answer was, when it was wrong

Chance is printed beside every table. Half these menus hold two options, so a
top-3 of 19/28 is worse than guessing (F13).

`--stage2 N` shortlists to N and hands them to the judge. The shortlist goes
in the app's menu order and its score block is trimmed to the lines that still
separate two shortlisted options (F7). With `--framing all`, the shortlist is
built from the framing with the best top-3, and the run says which.

NOTE — this scores the **retired** menu prompt.

The judge does not ask a menu any more. It shows the sentence before and after
the pass and takes one KEEP or REVERT per substitution; the prompt is compiled
in and `scripts/judge-verdicts.py` is what scores it. This script and its
cached menus are kept as the baseline, because every earlier round of this work
was scored here and a number with nothing to compare it to says nothing.

`--harvest` no longer works against the app: the dump it scrapes is the new
exchange, not a lettered menu. The committed cache in `tests/judge-menus.json`
still replays.
"""
import argparse
import json
import re
import string
import sys
from pathlib import Path
from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "tests/judge-menus.json"
recall = SourceFileLoader("recall", str(ROOT / "scripts/menu-recall.py")).load_module()
# For `ask` and for F6's sentinel rule, which is defined once, there.
tune = SourceFileLoader("tune", str(ROOT / "scripts/tune-judge.py")).load_module()

DEFAULT_MODEL = "Qwen/Qwen3-Reranker-0.6B"

# ── framings ─────────────────────────────────────────────────────────────────
# A reranker scores how well a document answers a query. Our candidates are the
# same sentence with one word changed, so they are all equally "about" any query
# describing the topic — and what is left to separate them is term overlap. The
# first framing here lists the vocabulary in the query and so scores a candidate
# up for *containing* a vocabulary name, which is backwards: the whole question
# is whether that name belongs there. The rest are attempts to give the model a
# query the right answer actually matches better.
#
# `reverse` ranks ascending, for a framing that describes the wrong answer.

FRAMINGS = {
    "terms": dict(
        instruct="The user is dictating. A speech recogniser mangles the names "
                 "they use often, so several readings of the same audio are in "
                 "play, differing only in those names. Judge whether this "
                 "reading is what the user actually said.",
        query="A dictated sentence. The user's vocabulary is: {terms} — "
              "colleagues, products and tools they talk about every day. They "
              "also talk about people and things that are not in that list.",
    ),
    "plain": dict(
        instruct="Judge whether this is a correct transcription of dictated "
                 "speech — every word being the word the speaker actually said.",
        query="A sentence the user dictated.",
    ),
    "fluent": dict(
        instruct="Judge whether the document is fluent, grammatical English "
                 "that a person would actually say. A sentence is not fluent "
                 "when a proper name stands where an ordinary verb or noun "
                 "belongs, or where two words have been run into one name.",
        query="A grammatical, natural English sentence where every word makes "
              "sense in its place.",
    ),
    "misheard": dict(
        instruct="Judge whether the document contains a speech-recognition "
                 "error: a proper name or product name written where an "
                 "ordinary English word was actually spoken, leaving a sentence "
                 "that does not parse.",
        query="A garbled transcription, where a proper name has replaced an "
              "ordinary word and the sentence no longer makes sense.",
        reverse=True,
    ),
    # Two rewordings of the same polarity. Picking the best of four framings on
    # twenty-four cases is exactly how a fluke gets reported as a finding, so
    # these are here to show whether the flip survives being said differently.
    "misheard-short": dict(
        instruct="Judge whether this sentence contains a transcription error.",
        query="A sentence with a word transcribed wrongly.",
        reverse=True,
    ),
    "misheard-long": dict(
        instruct="This is dictated speech that a recogniser has transcribed. "
                 "Judge whether one of the words is wrong — specifically a "
                 "brand, product or person's name printed where the speaker "
                 "actually said a common English word, or two common words run "
                 "together into a single name. The result is a sentence that a "
                 "native speaker would never produce.",
        query="A transcript containing a misrecognised word, where a name "
              "appears in a position no name could occupy.",
        reverse=True,
    ),
}


# ── prompt shapes ────────────────────────────────────────────────────────────
# Each reranker was trained against one exact string, and a reranker fed a
# string it was not trained on degrades quietly rather than failing. So these
# are transcribed from the source, not paraphrased: Qwen's from the model
# card's `format_instruction` / `prefix` / `suffix`, mixedbread's from
# `mxbai_rerank/mxbai_rerank_v2.py`. The instruction is the only part meant to
# be rewritten. The yes/no token ids come from each repo's `1_LogitScore`
# rather than from re-encoding, which is where an off-by-one hides.

def qwen3_prompt(instruct, query, document):
    system = ('Judge whether the Document meets the requirements based on the '
              'Query and the Instruct provided. Note that the answer can only '
              'be "yes" or "no".')
    body = f"<Instruct>: {instruct}\n<Query>: {query}\n<Document>: {document}"
    return (f"<|im_start|>system\n{system}<|im_end|>\n"
            f"<|im_start|>user\n{body}<|im_end|>\n"
            f"<|im_start|>assistant\n<think>\n\n</think>\n\n")


def mxbai_prompt(instruct, query, document):
    task = ("You are a search relevance expert who evaluates how well documents "
            "match search queries. For each query-document pair, carefully "
            "analyze the semantic relationship between them, then provide your "
            "binary relevance judgment (0 for not relevant, 1 for relevant).\n"
            "Relevance:")
    return ("<|im_start|>system\nYou are Qwen, created by Alibaba Cloud. You are "
            "a helpful assistant.<|im_end|>\n<|im_start|>user\n"
            f"instruction: {instruct}\nquery: {query}\n"
            f"document: {document}\n{task}<|im_end|>\n<|im_start|>assistant\n")


SHAPES = {                        # builder, true id, false id
    "qwen3": (qwen3_prompt, 9693, 2152),
    "mxbai": (mxbai_prompt, 16, 15),
}


def shape_for(name):
    return "mxbai" if "mxbai" in name.lower() else "qwen3"


# ── the model ────────────────────────────────────────────────────────────────

class Reranker:
    """One forward pass per candidate; the score is the yes/no logit gap.

    The gap is kept rather than the probability. Probabilities saturate — two
    candidates at 0.999 and 0.9999 look identical and are four nats apart — and
    the whole reason for using a reranker here is to get a usable distance.
    """

    def __init__(self, name):
        import mlx.core as mx
        from mlx_lm import load
        self.mx = mx
        self.model, self.tok = load(name)
        self.build, self.yes, self.no = SHAPES[shape_for(name)]

    def score(self, instruct, query, document):
        text = self.build(instruct, query, document)
        ids = self.mx.array([self.tok.encode(text, add_special_tokens=False)])
        logits = self.model(ids)[0, -1]
        return float(logits[self.yes] - logits[self.no])


# ── the acoustic evidence ────────────────────────────────────────────────────

SCORE_LINE = re.compile(r'"([^"]+)"\s+(-?\d+\.\d+)\s+"([^"]+)"\s+(-?\d+\.\d+)')


def slots(block):
    """The score block back into pairs: (reading, nats, reading, nats)."""
    return [(a, float(x), b, float(y))
            for a, x, b, y in SCORE_LINE.findall(block or "")]


def commits(option, spelling):
    """Does this reading commit to that spelling? Same test as `ctc_total`."""
    return spelling.strip(".,?!;:") in option


def trim_scores(block, options):
    """The score block cut down to what still separates these options (F7).

    A line keeps its place only if it passes both tests.

    It has to be a measurement. A 0.00 heard score is the sentinel, not a
    number (F6), so the rule is `tune-judge.strip_sentinels` — defined once,
    there.

    And the shortlisted options have to still disagree about it. Two of them
    must stand in different relations to the pair of spellings; a line every
    survivor answers the same way describes a choice that is no longer on the
    menu, and the judge then reads a number about an option it cannot pick.
    "Contains" is the crude test `ctc_total` already uses, and crude is right
    here: a sentence can hold both spellings at once ("Let's praise Praisy's
    work"), and that is a third relation, not a tie.

    Measured on the cached menus, top-3 shortlists, gemma4:e4b: order fix
    alone 23→24, this trim alone 23, both 25/28. The trim on its own is worse
    than nothing because it can strand a sentinel line as the only survivor,
    which is exactly the lying evidence F6 describes.

    The preamble is kept, but only while some score line survives. If none
    does, the whole block goes: prose promising numbers that are absent is
    worse than no prose.
    """
    if not block:
        return ""
    kept = []
    for line in tune.strip_sentinels(block).splitlines():
        found = SCORE_LINE.search(line)
        if not found:
            kept.append(line)
            continue
        a, _, b, _ = found.groups()
        stances = {(commits(o, a), commits(o, b)) for o in options}
        if len(stances) > 1:
            kept.append(line)
    if not any(SCORE_LINE.search(line) for line in kept):
        return ""
    return "\n".join(kept)


def ctc_total(option, pairs):
    """This option's acoustic score, summed over the slots it commits to.

    Each line of the score block is one uncertain stretch of audio with two
    spellings for it. An option picks one spelling per stretch, so summing the
    score of whichever spelling it contains gives that whole reading a number.
    A slot that matches neither spelling is skipped rather than guessed at.
    """
    total = 0.0
    for a, x, b, y in pairs:
        left, right = a.strip(".,?!;:") in option, b.strip(".,?!;:") in option
        if left and not right:
            total += x
        elif right and not left:
            total += y
    return total


# ── the run ──────────────────────────────────────────────────────────────────

def evaluate(cases, rank, fuse=None):
    """rank(case) -> [(score, option)] best first. Returns the tallies."""
    top1 = top3 = 0
    misses = []
    for case in cases:
        truth = recall.normalise(case["said"])
        ranked = rank(case)
        if fuse is not None:
            pairs = slots(case.get("scores"))
            ranked = sorted(((s + fuse * ctc_total(o, pairs), o)
                             for s, o in ranked), reverse=True)
        order = [recall.normalise(o) for _, o in ranked]
        place = order.index(truth) if truth in order else 99
        top1 += place == 0
        top3 += place < 3
        if place != 0:
            gap = ranked[0][0] - (ranked[place][0] if place < len(ranked) else 0)
            misses.append((case, ranked, place, gap))
    return top1, top3, misses


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--scores", action="store_true",
                    help="append the acoustic evidence to each candidate")
    ap.add_argument("--fuse", action="store_true",
                    help="sweep the weight on the CTC score")
    ap.add_argument("--framing", default="terms", choices=sorted(FRAMINGS) + ["all"])
    ap.add_argument("--stage2", type=int, nargs="?", const=3, default=0,
                    metavar="N", help="shortlist to N, then let the judge pick")
    ap.add_argument("--judge", default="gemma4:e4b")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    if not CACHE.exists():
        print("✗ no cache — run scripts/tune-judge.py --harvest first")
        return 2

    cases = [c for c in json.loads(CACHE.read_text())
             if recall.normalise(c["said"]) in [recall.normalise(o) for o in c["menu"]]]
    unreachable = len(json.loads(CACHE.read_text())) - len(cases)
    if args.limit:
        cases = cases[:args.limit]

    # What ranking at random would score, given these menu sizes. Half of them
    # hold two options, so a top-3 near 19 means nothing at all — this line is
    # here because the first run of this script was read as a good result.
    sizes = [len(c["menu"]) for c in cases]
    chance1 = sum(1 / n for n in sizes)
    chance3 = sum(min(3, n) / n for n in sizes)

    model = Reranker(args.model)
    name = args.model.split("/")[-1]
    print(f"\n  {name}   {len(cases)} menus, sizes {min(sizes)}–{max(sizes)}"
          f"   ({unreachable} never held the answer)")
    print(f"  chance                     top-1 {chance1:.1f}/{len(cases)}"
          f"   top-3 {chance3:.1f}/{len(cases)}\n")

    best = None
    for key in (sorted(FRAMINGS) if args.framing == "all" else [args.framing]):
        frame = FRAMINGS[key]
        cached = {}

        def rank(case, frame=frame, cached=cached):
            if id(case) in cached:
                return cached[id(case)]
            query = frame["query"].format(terms=case["terms"] or "none listed")
            tail = ("\n\nHow clearly the recogniser heard each spelling, closer "
                    "to zero being clearer:" + case["scores"].split("comparable.")[-1]
                    ) if args.scores and case.get("scores") else ""
            # A reversed framing describes the *wrong* answer, so its score is
            # negated here rather than sorted the other way. Everything
            # downstream — the fusion with the acoustic score, the margins in
            # the miss list — can then assume higher is better.
            sign = -1 if frame.get("reverse") else 1
            out = sorted(((sign * model.score(frame["instruct"], query, o + tail), o)
                          for o in case["menu"]), reverse=True)
            cached[id(case)] = out
            return out

        top1, top3, misses = evaluate(cases, rank)
        flag = "  ← below chance" if top1 < chance1 else ""
        print(f"  {key:<26} top-1 {top1:>2}/{len(cases)}   top-3 {top3:>2}/{len(cases)}{flag}")
        # The shortlist is only as good as the framing that built it, and the
        # second stage measures what the shortlist left reachable. Keeping the
        # last framing in the loop shortlisted with "terms" — alphabetically
        # last, and the one that scores below chance (F7).
        if best is None or (top3, top1) > (best[2], best[3]):
            best = (key, rank, top3, top1, misses)
    chosen_framing, rank, _, _, misses = best
    print()

    if args.stage2:
        # The reranker cannot pick, but it can rule out. The judge cannot rule
        # out sixteen options reliably, but it can pick from three. Neither
        # number below is worth anything on its own — `ceiling` is what the
        # shortlist left reachable, and `picked` is what the judge did with it.
        prompt = (ROOT / "tests/fixtures/retired-menu-prompt.md").read_text().strip()
        n = args.stage2
        ceiling = kept = 0
        ceiling_chance = picked_chance = 0.0
        for case in cases:
            truth = recall.normalise(case["said"])
            top = [o for _, o in rank(case)[:n]]
            # Back into the app's own order, decoder's reading first. The
            # reranker chooses *which* readings survive, not the order they
            # are read in: position in the list is worth about eight points
            # to the judge, and letting the reranker set it cost a case (F7).
            place = {o: i for i, o in enumerate(case["menu"])}
            short = sorted(top, key=lambda o: place.get(o, len(place)))
            ceiling_chance += min(n, len(case["menu"])) / len(case["menu"])
            if truth not in [recall.normalise(o) for o in short]:
                continue
            ceiling += 1
            picked_chance += 1 / len(short)
            chosen = tune.ask(args.judge, prompt.replace("{terms}", case["terms"]),
                              short, trim_scores(case.get("scores") or "", short))
            kept += chosen is not None and recall.normalise(chosen) == truth
        print(f"  two-stage, top-{n} then {args.judge}, shortlisted by "
              f"framing {chosen_framing!r}")
        print(f"    shortlist ceiling        {ceiling}/{len(cases)}"
              f"   (chance {ceiling_chance:.1f})")
        print(f"    picked                   {kept}/{len(cases)}"
              f"   (chance {picked_chance:.1f})\n")

    if args.fuse:
        print("\n  fused with the acoustic score — total = logit gap + λ · nats")
        print(f"    {'chance':<7} top-1 {chance1:>4.1f}/{len(cases)}"
              f"  top-3 {chance3:>4.1f}")
        for lam in (0.0, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0, 1.5, 2.0):
            a, b, _ = evaluate(cases, rank, fuse=lam)
            bar = "█" * a
            print(f"    λ {lam:<5} top-1 {a:>4}/{len(cases)}  top-3 {b:>4}  {bar}")

    if args.verbose and misses:
        print(f"\n{'=' * 72}\nranked wrong ({len(misses)})\n{'=' * 72}")
        for case, ranked, place, gap in misses:
            where = f"place {place + 1}" if place < 90 else "not ranked"
            print(f"\n{case['wav'][22:-4]}   true reading at {where}, {gap:.2f} behind")
            print(f"  said:  {case['said'][:150]}")
            for score, option in ranked[:3]:
                mark = "✓" if recall.normalise(option) == recall.normalise(case["said"]) else " "
                print(f"  {mark} {score:>7.2f}  {option[:150]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
