#!/usr/bin/env python3
"""Score a prompt against tests/spelling-cases.yaml on a local Ollama model.

    scripts/validate-prompt.py gemma4:e4b
    scripts/validate-prompt.py gemma4:e4b --variant v2 --verbose

Prompt variants live in this file so they can be compared directly; the
winner gets copied into LocalLLM.swift.
"""
import argparse, json, sys, time, urllib.request, pathlib, re

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")

ROOT = pathlib.Path(__file__).resolve().parent.parent

VARIANTS = {
# What is in LocalLLM.swift today: silence for the no-match case.
"v1": """Map a misheard word to the spelling the speaker just read out.

You get a source transcription, and a correction transcription in which the speaker says a word then spells it letter by letter.

Output exactly one line:
<word exactly as it appears in the source> => <the spelled letters joined up>

Output nothing at all if no word in the source plausibly matches.

- Copy the word from the SOURCE. The correction transcription mishears it; ignore its version.
- The source span may be more than one word.
- Join the spelled letters and capitalise naturally.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin => Tasmeen

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal => Vercel""",

# Emitting zero tokens is unnatural for a model; give the null case a token.
"v2": """Map a misheard word to the spelling the speaker just read out.

You get a source transcription, and a correction transcription in which the speaker says a word then spells it letter by letter.

Reply with exactly one line, and nothing else:
<span exactly as it appears in the source> => <the spelled letters joined up>
or
NO MATCH

- The left side must be copied character for character from the SOURCE. The correction transcription mishears the name a second time; ignore how it spells it there.
- The source span is often two or three words, because recognition splits names it does not know.
- The right side is only the spelled-out letters, joined and capitalised normally.
- Reply NO MATCH when nothing in the source sounds like the spelled word.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin => Tasmeen

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal => Vercel

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties => Kubernetes""",

# v2 plus: the span is the name only; letters are copied exactly; casing is
# fixed; and a second NO MATCH example where an ordinary English word is the
# nearest thing in the source.
"v3": """Map a misheard name to the spelling the speaker just read out.

You get a source transcription, and a correction transcription in which the speaker says a name then spells it letter by letter.

Reply with exactly one line, and nothing else:
<span exactly as it appears in the source> => <the spelled letters joined up>
or
NO MATCH

Left side:
- Copy it character for character from the SOURCE. The correction transcription mishears the name a second time; ignore how it appears there.
- Include only the name itself. Never include ordinary words around it such as is, the, and, was, on.
- It is often two or three words, because recognition splits names it does not know.

Right side:
- Use the spelled letters exactly, in the order given. Do not add, drop or reorder any.
- One capital at the start, the rest lowercase.

Reply NO MATCH when nothing in the source sounds like the spelled name — including when the only nearby candidate is a common English word.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin => Tasmeen

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal => Vercel

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties => Kubernetes

source: When is handling the deploy
correction: New yen spells N G U Y E N
When => Nguyen""",

# v2's span behaviour (v3's "never include ordinary words" over-trimmed
# "Anna ees" to "Anna"), plus v3's extra NO MATCH example. Examples teach
# trimming better than a rule does.
"v4": """Map a misheard name to the spelling the speaker just read out.

You get a source transcription, and a correction transcription in which the speaker says a name then spells it letter by letter.

Reply with exactly one line, and nothing else:
<span exactly as it appears in the source> => <the spelled letters joined up>
or
NO MATCH

- The left side must be copied character for character from the SOURCE. The correction transcription mishears the name a second time; ignore how it spells it there.
- The source span is often two or three words, because recognition splits names it does not know. Take the whole name, and only the name.
- The right side is the spelled letters, in the order given, joined up with one capital at the start.
- Reply NO MATCH when nothing in the source sounds like the spelled name, including when the nearest candidate is an ordinary English word.

source: I work with Tasmin
correction: Das mean spells T-A-S-M-E-E-N
Tasmin => Tasmeen

source: I work with Sarah
correction: Tasmin spells T-A-S-M-E-E-N
NO MATCH

source: I like apples
correction: Oranges spells O-R-A-N-G-E-S
NO MATCH

source: We deployed to Versal yesterday
correction: Versoff spells V E R C E L
Versal => Vercel

source: The Coober netties cluster is down
correction: Kuber nettis spells K U B E R N E T E S
Coober netties => Kubernetes

source: When is handling the deploy
correction: New yen spells N G U Y E N
When => Nguyen

source: Anna ees joined the design team
correction: Anna east spells A N A I S
Anna ees => Anais""",
}

def ask(model, system, src, corr, think, predict):
    body = {"model": model, "system": system,
            "prompt": f"source: {src}\ncorrection: {corr}",
            "stream": False, "think": think,
            "options": {"temperature": 0, "num_predict": predict}}
    req = urllib.request.Request("http://localhost:11434/api/generate",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    t = time.time()
    with urllib.request.urlopen(req, timeout=600) as r:
        d = json.load(r)
    return (d.get("response") or "").strip(), time.time() - t

def normalise(text):
    text = " ".join(text.split())
    # "I like apples => NO MATCH" is the right decision, clumsily formatted.
    if not text or re.search(r"\bno match\b|\bnone\b|\[nothing\]", text, re.I):
        return "NO MATCH"
    return text

LETTERS = re.compile(r"\b(?:[A-Za-z0-9][\s\-.]+){2,}[A-Za-z0-9]\b")

def spelled_out(correction):
    """The spelling, taken from the text rather than the model — this is what
    LocalLLM.swift does, and it is why the model's right side does not matter."""
    m = LETTERS.search(correction)
    if not m:
        return None
    joined = re.sub(r"[^A-Za-z0-9]", "", m.group(0))
    return joined[:1].upper() + joined[1:].lower() if len(joined) >= 3 else None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--variant", default="v2", choices=sorted(VARIANTS))
    ap.add_argument("--think", action="store_true")
    ap.add_argument("--predict", type=int, default=24)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    cases = yaml.safe_load((ROOT / "tests/spelling-cases.yaml").read_text())["cases"]
    system = VARIANTS[args.variant]

    ask(args.model, system, "warm up", "warm up spells W A R M", args.think, args.predict)

    passed, total_time, failures = 0, 0.0, []
    left_passed = [0]
    pipe_passed = [0]
    pipe_failures = []
    for case in cases:
        got, dt = ask(args.model, system, case["source"], case["correction"],
                      args.think, args.predict)
        total_time += dt
        got_n, want_n = normalise(got), normalise(case["expect"])
        ok = got_n.lower() == want_n.lower()
        passed += ok
        left_ok = (got_n.split("=>")[0].strip().lower()
                   == want_n.split("=>")[0].strip().lower())
        left_passed[0] += left_ok

        # The real pipeline: model picks the span, regex builds the spelling.
        if got_n == "NO MATCH":
            pipeline = "NO MATCH"
        else:
            span = got_n.split("=>")[0].strip()
            spelling = spelled_out(case["correction"])
            pipeline = f"{span} => {spelling}" if spelling else got_n
        pipe_ok = pipeline.lower() == want_n.lower()
        pipe_passed[0] += pipe_ok
        if not pipe_ok:
            pipe_failures.append((case["source"], pipeline, want_n))
        if not ok:
            failures.append((case["source"], got_n, want_n))
        if args.verbose:
            print(f"  {'✓' if ok else '✗'} {dt:5.2f}s {got_n[:44]!r:46} want {want_n[:34]!r}")

    print(f"\n{args.model}  variant={args.variant}  think={args.think}")
    n = len(cases)
    print(f"  full line   {passed}/{n} = {100*passed/n:.0f}%")
    print(f"  left side   {left_passed[0]}/{n} = {100*left_passed[0]/n:.0f}%  <- what the model must get right")
    print(f"  PIPELINE    {pipe_passed[0]}/{n} = {100*pipe_passed[0]/n:.0f}%  <- model span + regex spelling")
    print(f"  {total_time/n:.2f}s avg")
    if pipe_failures:
        print("  pipeline failures:")
        for src, got, want in pipe_failures:
            print(f"    {src[:40]!r}  got {got!r}  want {want!r}")
    if failures and not args.verbose:
        print("  failures:")
        for src, got, want in failures:
            print(f"    {src[:40]!r}\n      got  {got!r}\n      want {want!r}")

main()
