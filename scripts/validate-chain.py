#!/usr/bin/env python3
"""Per-word judging, independently versus in sequence.

    scripts/validate-chain.py gemma4:e4b slots.json
    scripts/validate-chain.py gemma4:12b slots.json --sequential

The shipped judge asks about every proposal against the *same* original
sentence, so two names in one clause are decided in ignorance of each other.
Sequential mode threads them: slot 2 is judged against the sentence as slot 1
left it, so "So Mirza and Mirra goes to the movies" is what the second call
reads once the first has resolved.

Same prompt either way — the one measured at 91% on tests/judge-cases.yaml —
so the only variable is what the sentence says when the question is asked.
"""
import argparse, importlib.util, json, os, pathlib, sys, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
ALL_TERMS = ("Arexvy, Claude, Matthieu, Mirza, Ollama, Praisy, Redrock,"
             " Supabase, Tasmeen, Vercel")
RIGHT = {
    ("Versailles", "Vercel"), ("Versailles.", "Vercel"), ("Myrza", "Mirza"),
    ("Precy", "Praisy"), ("RXV", "Arexvy"), ("RX V", "Arexvy"),
    ("on olma.", "Ollama"), ("praised.", "Praisy"),
}


def shipped():
    path = ROOT / "examples/transforms/verify_names/verify_names.py"
    spec = importlib.util.spec_from_file_location("verify_names", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("cases")
    ap.add_argument("--sequential", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    os.environ["PARROTFLOW_JUDGE_MODEL"] = args.model
    vn = shipped()
    cases = json.loads(pathlib.Path(args.cases).read_text())

    keep_ok = keep_total = change_ok = change_total = 0
    elapsed, wrong, calls = 0.0, [], 0

    for case in cases:
        # Time order, so "the previous one" means the word before it.
        slots = sorted(case["slots"], key=lambda s: s["start"])
        sentence = case["said"]
        for slot in slots:
            heard = slot["heard"]
            # The best-scoring candidate, which is what the shipped path would
            # be handed for this span.
            best = max(zip(slot["candidates"], slot["scores"]), key=lambda p: p[1])[0]
            asked = sentence if args.sequential else case["said"]
            started = time.time()
            try:
                yes = vn.approved(asked, heard, best, ALL_TERMS)
            except Exception:
                yes = False
            elapsed += time.time() - started
            calls += 1

            want_change = (heard, best) in RIGHT
            ok = yes == want_change
            if want_change:
                change_total += 1; change_ok += ok
            else:
                keep_total += 1; keep_ok += ok
            if not ok:
                wrong.append((heard, best, want_change, asked[:64]))
            if args.sequential and yes:
                sentence = sentence.replace(heard, best, 1)
            if args.verbose:
                print(f"  {'ok  ' if ok else 'FAIL'} {heard!r} -> {best!r}"
                      f"  said yes={yes}, want={want_change}")

    total = keep_total + change_total
    print(f"\n{args.model} {'sequential' if args.sequential else 'independent'}"
          f"  ({len(cases)} sentences, {total} slots)")
    print(f"  keep the word   {keep_ok}/{keep_total}"
          f"  {keep_ok / max(keep_total,1) * 100:.0f}%")
    print(f"  use the name    {change_ok}/{change_total}"
          f"  {change_ok / max(change_total,1) * 100:.0f}%")
    print(f"  overall         {keep_ok + change_ok}/{total}"
          f"  {(keep_ok + change_ok) / max(total,1) * 100:.0f}%"
          f"   {elapsed / max(calls,1):.2f}s per call")
    if wrong and not args.verbose:
        print(f"\n  wrong ({len(wrong)}):")
        for heard, term, want, said in wrong[:12]:
            print(f"    {heard!r} -> {term!r}  should {'change' if want else 'keep'}")
            print(f"      {said}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
