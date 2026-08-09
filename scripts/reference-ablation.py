#!/usr/bin/env python3
"""Replay the labelled clips through any number of arms and count the damage.

    scripts/reference-ablation.py --arm off=DIR --arm on=DIR --runs 3 --out FILE

`scripts/vocab-ablation.py` on `origin/experiment/does-vocabulary-pay` does
this for exactly two arms and reports one comparison. The reference-matching
prototype needs three, and the third differs from the second by an environment
variable rather than by a config directory. So an arm here is

    name=CONFIG_DIR[,VAR=VALUE...]

and every pair of arms is reported against every other. Nothing else changed:
the same `tests/menu-cases.yaml`, the same `menu-recall.normalise` and
`menu-recall.majority`, the same majority-of-N over replays because replay is
nondeterministic (F12a).

The three counts, fixed before the run:

    correct   clips whose majority transcript matches the label
    wins      B right where A is wrong
    losses    A right where B is wrong

Read wins and losses together. A filter that removes as many wins as losses
has switched the feature off, and the net alone hides that.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parent.parent
recall = SourceFileLoader("recall", str(ROOT / "scripts/menu-recall.py")).load_module()
CASES = ROOT / "tests/menu-cases.yaml"
CLIPS = Path.home() / "Recordings/ParrotFlow Dev"


def cases_with_class():
    """(wav, said, is_term) for every labelled clip, in file order.

    Lifted from `vocab-ablation.py`. Every clip carries a `# picked up:` line
    naming how it entered the set, and the controls say so in words.
    """
    out, cur = [], None
    for line in CASES.read_text().splitlines():
        s = line.strip()
        if s.startswith("- wav:"):
            if cur:
                out.append(cur)
            cur = {"wav": s.split(":", 1)[1].strip(),
                   "control": False, "said": None, "open": False}
        elif cur is not None and s.startswith("# picked up:"):
            cur["control"] = "a control" in s
        elif cur is not None and s.startswith("said:"):
            body = s.split(":", 1)[1].split("#")[0].strip()
            cur["said"] = body.strip('"') or None
            cur["open"] = True
        elif cur is not None and cur["open"] and s and not s.startswith("#"):
            cur["said"] = (cur["said"] or "") + " " + s.strip('"')
    if cur:
        out.append(cur)
    return [(c["wav"], c["said"].strip(), not c["control"])
            for c in out if c["said"]]


def parse_arm(spec):
    name, rest = spec.split("=", 1)
    parts = rest.split(",")
    env = {}
    for extra in parts[1:]:
        key, value = extra.split("=", 1)
        env[key] = value
    return {"name": name, "dir": parts[0], "env": env}


def transcribe(wav, arm):
    """One clip through the app under one arm. Returns the final transcript."""
    environment = dict(os.environ)
    environment["PARROTFLOW_CONFIG_DIR"] = arm["dir"]
    environment.update(arm["env"])
    dump = Path(tempfile.mkdtemp()) / "menu.txt"
    environment["PARROTFLOW_JUDGE_DUMP"] = str(dump)
    done = subprocess.run(
        [recall.APP, "--transcribe", str(CLIPS / wav)],
        capture_output=True, text=True, env=environment, timeout=600,
    )
    lines = (done.stdout + done.stderr).splitlines()
    final = None
    for i, line in enumerate(lines):
        if "transcript" in line and "─" in line and i + 1 < len(lines):
            final = lines[i + 1].strip()
    return final or ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", action="append", required=True,
                    help="name=CONFIG_DIR[,VAR=VALUE...]")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--out", default="", help="write per-clip JSON here")
    args = ap.parse_args()

    if not Path(recall.APP).exists():
        print(f"✗ {recall.APP} not found — run `make app` first")
        return 2

    arms = [parse_arm(spec) for spec in args.arm]
    cases = cases_with_class()
    if args.limit:
        cases = cases[:args.limit]

    rows = []
    started = time.time()
    for n, (wav, said, is_term) in enumerate(cases, 1):
        truth = recall.normalise(said)
        row = {"wav": wav, "said": said, "term": is_term, "runs": {}}
        for arm in arms:
            texts = [transcribe(wav, arm) for _ in range(args.runs)]
            ok, moved = recall.majority(
                [recall.normalise(t) == truth for t in texts])
            row["runs"][arm["name"]] = {"texts": texts, "ok": ok, "flipped": moved}
        rows.append(row)
        marks = " ".join(
            f"{a['name']}={'ok' if row['runs'][a['name']]['ok'] else '--'}"
            for a in arms)
        rate = (time.time() - started) / n
        print(f"  {n:>3}/{len(cases)}  {marks}  {wav}"
              f"  [{rate:.1f}s/clip, {(len(cases) - n) * rate / 60:.0f} min left]",
              file=sys.stderr, flush=True)
        if args.out:
            Path(args.out).write_text(json.dumps(rows, indent=1))

    report(rows, [a["name"] for a in arms])
    return 0


def report(rows, names):
    def block(label, subset):
        print(f"\n{label}  ({len(subset)} clips)")
        print(f"  {'arm':<12} {'correct':>8} {'flips':>7}")
        for name in names:
            correct = sum(1 for r in subset if r["runs"][name]["ok"])
            flips = sum(1 for r in subset if r["runs"][name]["flipped"])
            print(f"  {name:<12} {correct:>8} {flips:>7}")
        print(f"\n  {'A -> B':<26} {'wins':>6} {'losses':>7} {'net':>6}")
        for i, a in enumerate(names):
            for b in names[i + 1:]:
                wins = sum(1 for r in subset
                           if r["runs"][b]["ok"] and not r["runs"][a]["ok"])
                losses = sum(1 for r in subset
                             if r["runs"][a]["ok"] and not r["runs"][b]["ok"])
                print(f"  {a + ' -> ' + b:<26} {wins:>6} {losses:>7} "
                      f"{wins - losses:>+6}")

    block("ALL", rows)
    block("about a term", [r for r in rows if r["term"]])
    block("controls", [r for r in rows if not r["term"]])


if __name__ == "__main__":
    sys.exit(main())
