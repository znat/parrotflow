#!/usr/bin/env python3
"""Replay the labelled clips through any number of arms and count the damage.

    scripts/vocab-ablation.py --arm off=DIR --arm today=DIR [--runs 3] [--out FILE]

An arm is a config directory, plus any environment variables that arm needs:

    name=CONFIG_DIR[,VAR=VALUE...]

Every pair of arms is reported against every other, wins and losses apart,
split by class, as the majority of `--runs N` replays with a flip count. Give
it two arms and it answers "does the vocabulary pass pay for itself"; give it
five and it answers "which of these five is best", which is the question the
reference-matching prototype asked.

Three counts, fixed before the run:

    correct   clips whose majority transcript matches the hand label
    wins      B right where A is wrong
    losses    A right where B is wrong

**Read wins and losses together, and read the correct count beside them.** A
filter that removes as many wins as losses has switched the feature off, and
the net alone hides that. An arm that vetoes everything looks excellent on net.
Put the arm that does nothing first, so every pair is reported against it.

## Switching the pass off honestly — three different off arms

They are not the same measurement. Know which one you want.

    no vocabulary at all       empty `terms:` in a scratch `vocabulary.yaml`.
                               No acoustic context, no rules,
                               `vocabulary.count == 0`, so the judge stage's
                               `when:` skips it too.
    the acoustic path off,     `acoustic: false` in `vocabulary.yaml`, with
    the rules kept             every term and every `heard:` list left in place.
    a third of the pass off    `--transcribe --no-vocab`, which is almost never
                               what you meant.

`--no-vocab` sets `config.vocabulary.acoustic = false` and nothing else
(`TranscribeCommand.swift`). The `heard:`/`pronunciations:` lists still become
`Config.vocabularyRules`, those rules still write names in `replacements`, and
they still raise `vocabulary.count`, so the `vocabulary:` judge stage still
fires. This harness never passes it; arms differ by config directory instead.

## The scratch config recipe

Never run against `~/.config/parrotflow-dev`. Copy it once per arm:

    S=/tmp/ablation
    for d in cfg-on cfg-off; do
      mkdir -p $S/$d
      cp ~/.config/parrotflow-dev/{config.yaml,vocabulary.yaml,verify_names.md} $S/$d/
      cp -R ~/.config/parrotflow-dev/transforms $S/$d/
      printf '\\naudio:\\n  output_dir: %s\\n' "$S/audio" >> $S/$d/config.yaml
    done

The `audio.output_dir` line is not optional. Without it a 2000-clip run appends
2000 entries to the speaker's own `trace.jsonl` and writes 2000 wavs beside
their real dictations. Anything that reads `voice/samples/<Term>/` — the
reference-matching arms do — needs `voice/` copied in as well. None of it is
committable: `scripts/check-no-voice.sh` refuses a repository carrying any of
it.

Then edit each copy to be the arm it is named after. This harness runs
`--check-config` under every arm before the first clip, so a directory the app
would refuse costs a second rather than the whole run.

## Noise

Replay is nondeterministic (F12a): the same clip replayed ten times gives term
scores spread over 5 nats on a long clip. So `--runs N` replays each clip N
times per arm and keeps the per-clip majority, and a clip that did not agree
with itself is counted as a flip. **The flip count is what says whether a small
difference means anything.** A single-run number within two cases of the one it
is compared with decides nothing.

## The split

Read off the case file, not guessed from the text. Every clip carries a
`# picked up:` line saying how it entered the set, and the 73 controls say so
in words: "No vocabulary term, a control". A single total hides a control
moving wrong while a term clip moves right, so the totals are always split.

## Re-running part of a set

`--limit N` takes the first N clips, which is for smoke tests. `--only FILE`
takes a list of wav names, one per line, `#` comments allowed — that is how you
re-run just the clips two arms disagreed on without paying for the whole set
again.

Ported from `scripts/vocab-ablation.py` on
`origin/experiment/does-vocabulary-pay` and `scripts/reference-ablation.py` on
`origin/proto/reference-matching`, which were the same harness with two arms
and with N. `scripts/vocab-losses.py` reads the `--out` JSON this writes and
prints the losing clips one by one.
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


def classes():
    """{wav: is_control}, read off the `# picked up:` line of each entry.

    The class is in the case file because it was decided when the clip entered
    the set. Guessing it from the text — "does a term appear?" — would put a
    clip the pass wrongly wrote a name into on the wrong side of the split,
    which is exactly the clip the split exists to find.
    """
    out, wav = {}, None
    for line in recall.CASES.read_text().splitlines():
        s = line.strip()
        if s.startswith("- wav:"):
            wav = s.split(":", 1)[1].strip()
            out[wav] = False
        elif wav and s.startswith("# picked up:"):
            out[wav] = "a control" in s
    return out


def cases_with_class(only=None):
    """(wav, said, is_term) for every labelled clip, in file order."""
    control = classes()
    cases = [(wav, said, not control.get(wav, False))
             for wav, said in recall.load_cases() if said]
    if only is None:
        return cases
    missing = only - {wav for wav, _, _ in cases}
    if missing:
        raise SystemExit(f"✗ not a labelled clip in {recall.CASES.name}: "
                         + ", ".join(sorted(missing)))
    return [c for c in cases if c[0] in only]


def read_only(path):
    """The wav names in a `--only` file: one per line, `#` comments allowed."""
    names = set()
    for line in Path(path).read_text().splitlines():
        s = line.split("#")[0].strip()
        if s:
            # The first field, so a line copied out of a progress log works.
            names.add(s.split()[0])
    if not names:
        raise SystemExit(f"✗ {path} names no clips")
    return names


def parse_arm(spec):
    if "=" not in spec:
        raise SystemExit(f"✗ --arm {spec}: expected name=CONFIG_DIR[,VAR=VALUE]")
    name, rest = spec.split("=", 1)
    parts = rest.split(",")
    env = {}
    for extra in parts[1:]:
        if "=" not in extra:
            raise SystemExit(f"✗ --arm {spec}: `{extra}` is not VAR=VALUE")
        key, value = extra.split("=", 1)
        env[key] = value
    if not Path(parts[0]).is_dir():
        raise SystemExit(f"✗ --arm {name}: {parts[0]} is not a directory")
    return {"name": name, "dir": parts[0], "env": env}


def environment_for(arm, dump):
    environment = dict(os.environ)
    environment["PARROTFLOW_CONFIG_DIR"] = arm["dir"]
    environment.update(arm["env"])
    # Not read here. It is set so the judge's menu lands in scratch rather than
    # wherever an inherited PARROTFLOW_JUDGE_DUMP points.
    environment["PARROTFLOW_JUDGE_DUMP"] = str(dump)
    return environment


def check_config(arm, dump):
    """`--check-config` under this arm, before the first clip of a long run.

    A config the app refuses fails at the first clip anyway. Failing here costs
    a second; failing there costs however long the run had left. The vocabulary
    lines are printed because they are how you tell the arms apart — an arm
    named `off` whose directory was never edited says so here and nowhere else.
    """
    done = subprocess.run(
        [recall.APP, "--check-config"], capture_output=True, text=True,
        env=environment_for(arm, dump), timeout=120,
    )
    said = [line.strip() for line in (done.stdout + done.stderr).splitlines()
            if "vocabulary:" in line]
    print(f"  {arm['name']:<12} {arm['dir']}")
    for line in said or ["(no vocabulary line — no terms in this arm)"]:
        print(f"    {line}")
    if done.returncode != 0:
        print(f"✗ arm {arm['name']}: --check-config refused {arm['dir']}")
        print((done.stdout + done.stderr).strip())
        return False
    return True


def transcribe(wav, arm, dump):
    """One clip through the app under one arm. Returns the final transcript.

    A replay that did not happen is not a wrong answer, and the difference has
    to be kept. The app exits 0 and prints a transcript block whenever it ran;
    a non-zero exit, or no block at all, means there is no measurement for this
    clip. Scoring that as "the arm got it wrong" would move a real count by a
    real clip for a reason that has nothing to do with the arm, and nothing in
    the report would say so — which is how a harness lies quietly. So it stops.
    `--out` is written every clip, so an abort at clip 90 of 141 still leaves
    90 clips of evidence behind.

    A clip that decodes to nothing is a different thing and is a measurement:
    the app prints its block with `(empty)` in it, which no label matches, so
    the clip counts wrong under that arm. That is the answer, not a failure.
    """
    done = subprocess.run(
        [recall.APP, "--transcribe", str(recall.CLIPS / wav)],
        capture_output=True, text=True, env=environment_for(arm, dump),
        timeout=600,
    )
    lines = (done.stdout + done.stderr).splitlines()
    final = None
    for i, line in enumerate(lines):
        if "transcript" in line and "─" in line and i + 1 < len(lines):
            final = lines[i + 1].strip()
    if done.returncode != 0 or final is None:
        why = (f"exit {done.returncode}" if done.returncode
               else "no transcript in its output")
        raise SystemExit(f"✗ arm {arm['name']} on {wav}: the app gave {why}\n"
                         + (done.stdout + done.stderr).strip())
    return final


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arm", action="append", required=True,
                    help="name=CONFIG_DIR[,VAR=VALUE...]; put the arm that "
                         "does nothing first")
    ap.add_argument("--runs", type=int, default=3,
                    help="replays per clip per arm; the majority decides (F12a)")
    ap.add_argument("--limit", type=int, default=0,
                    help="the first N clips — for a smoke test, not a number")
    ap.add_argument("--only", default="",
                    help="a file of wav names to re-run, one per line")
    ap.add_argument("--out", default="", help="write per-clip JSON here")
    args = ap.parse_args()

    if args.runs < 1:
        print("✗ --runs must be at least 1")
        return 2
    if not Path(recall.APP).exists():
        print(f"✗ {recall.APP} not found — run `make app` first")
        return 2

    arms = [parse_arm(spec) for spec in args.arm]
    if len({a["name"] for a in arms}) != len(arms):
        print("✗ two arms share a name — the report could not tell them apart")
        return 2
    cases = cases_with_class(read_only(args.only) if args.only else None)
    if args.limit:
        cases = cases[:args.limit]
    if not cases:
        print("✗ no labelled clips selected")
        return 2

    dump = Path(tempfile.mkdtemp()) / "menu.txt"
    print(f"{len(arms)} arm(s), {len(cases)} clip(s), {args.runs} run(s) each:")
    # Every arm, not the first bad one: a run is about to cost 25 minutes, so
    # the operator should learn about both broken directories at once.
    if not all([check_config(arm, dump) for arm in arms]):
        return 2

    rows = []
    started = time.time()
    for n, (wav, said, is_term) in enumerate(cases, 1):
        truth = recall.normalise(said)
        row = {"wav": wav, "said": said, "term": is_term, "runs": {}}
        for arm in arms:
            texts = [transcribe(wav, arm, dump) for _ in range(args.runs)]
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
        # Written every clip, not at the end: a run interrupted at clip 90 of
        # 141 still has 90 clips of evidence, and this is a 25-minute run.
        if args.out:
            Path(args.out).write_text(json.dumps(rows, indent=1))

    report(rows, [a["name"] for a in arms], args.runs)
    return 0


def report(rows, names, runs):
    def block(label, subset):
        print(f"\n{label}  ({len(subset)} clips)")
        print(f"  {'arm':<12} {'correct':>8} {'flips':>7}")
        for name in names:
            correct = sum(1 for r in subset if r["runs"][name]["ok"])
            flips = sum(1 for r in subset if r["runs"][name]["flipped"])
            print(f"  {name:<12} {correct:>8} {flips:>7}")
        if len(names) < 2:
            return
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

    print(f"\n  correct is out of the clips in that block, majority of {runs} "
          "run(s) per clip.")
    print("  wins and losses are B against A. Read them beside the correct "
          "count and beside")
    print(f"  {names[0]}, the first arm — an arm that removes everything wins "
          "on net.")
    if runs == 1:
        print("  one run per clip — these numbers carry replay noise (F12a);"
              " use --runs 3 before quoting them")


if __name__ == "__main__":
    sys.exit(main())
