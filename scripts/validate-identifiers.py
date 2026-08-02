#!/usr/bin/env python3
"""Score an identifier transform against tests/identifier-cases.yaml.

    scripts/validate-identifiers.py gemma4:e4b
    scripts/validate-identifiers.py gemma4:e4b --variant v2 --verbose
    scripts/validate-identifiers.py none --code-only    # the no-model control

The question: can one prompt turn a name said out loud into the identifier a
language spells it as, well enough to leave switched on? If it can, the whole
feature is a `transforms:` entry plus a pipeline line in config.yaml and
nothing enters the app. If it cannot, the fallback is a prompt that only marks
the names and a `replace:` table that cases them — which needs a case operator
the substitution engine does not have today.

Two scores, because the halves fail differently and only one of them is
survivable. `change` asks for a conversion and scores it exactly. `keep` must
come back byte for byte: this transform runs on every transcript in its
pipeline, so a model that edits sentences nobody asked about makes the feature
unusable however well it cases names.

The control is not a strawman here. A regex for "called X" plus a casing
function is a plausible implementation of the whole feature, so `--code-only`
is the line the model has to beat to justify the second of latency.

Composition mirrors PromptRunner.compose for a pipeline transform — no
instruction, so the prompt is the system message and the transcript is the
user message — and the cleanup is a port of PromptRunner.clean. A number
measured any other way describes code the app does not run.
"""
import argparse, json, re, subprocess, sys, time, unicodedata, urllib.request, pathlib

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")

ROOT = pathlib.Path(__file__).resolve().parent.parent
CASES = ROOT / "tests" / "identifier-cases.yaml"

# --- prompt variants -------------------------------------------------------
#
# Each is what would go in `transforms: - name: identifiers / prompt: |`.

VARIANTS = {}

# v1 — the rules, no examples. The baseline every later variant has to beat,
# and the one that says how much of this a model already knows.
VARIANTS["v1"] = """\
The text is a dictated sentence. When it introduces a name for a function, \
variable, class or constant, rewrite that name as an identifier. Leave every \
other word exactly as it is.

Use the convention of the language the sentence names:

- python, rust, ruby, elixir: snake_case
- javascript, typescript, java, go, swift, php: camelCase
- a class or a type: PascalCase
- a constant: SCREAMING_SNAKE_CASE
- no language named: camelCase

Only a name the sentence actually introduces — "a function called X", "une \
variable qui s'appelle X". A sentence that names nothing comes back unchanged, \
word for word.

Return only the text.
"""

# v2 — v1 plus examples, including two that change nothing. The rules alone
# cannot show where a name ends, and "unchanged" is a behaviour no rule has
# ever taught as well as an instance of it.
VARIANTS["v2"] = """\
The text is a dictated sentence. When it introduces a name for a function, \
variable, class or constant, rewrite that name as an identifier. Leave every \
other word exactly as it is.

Use the convention of the language the sentence names:

- python, rust, ruby, elixir: snake_case
- javascript, typescript, java, go, swift, php: camelCase
- a class or a type: PascalCase
- a constant: SCREAMING_SNAKE_CASE
- no language named: camelCase

Only a name the sentence actually introduces — "a function called X", "une \
variable qui s'appelle X". A sentence that names nothing comes back unchanged, \
word for word.

Return only the text.

text: add a rust function called read config file
add a rust function called read_config_file

text: a variable named retry count
a variable named retryCount

text: une classe qui s'appelle lecteur audio
une classe qui s'appelle LecteurAudio

text: the retry count is too high and it hammers the api
the retry count is too high and it hammers the api

text: we talked about python packaging for most of the afternoon
we talked about python packaging for most of the afternoon
"""

# v3 — v2, aimed at the one job left for a model: a naming with no marker in
# front of it. "call it max retries", "rename the variable to retry count".
# The script declines those by construction, so if a prompt is worth a second
# anywhere in this feature it is here. Examples of that shape, and the
# convention rule sharpened, because v2's failures on it were conventions
# (camelCase where python wants snake) rather than spans.
VARIANTS["v3"] = """\
The text is a dictated sentence. When it gives a name to a function, variable, \
class or constant, rewrite that name as an identifier. Leave every other word \
exactly as it is.

The convention is decided by the language named anywhere in the sentence:

- python, rust, ruby, elixir: snake_case
- javascript, typescript, java, go, swift, php: camelCase
- a class or a type: PascalCase
- a constant: SCREAMING_SNAKE_CASE
- no language named anywhere: camelCase

A name can be given without the word "called" — "call it X", "rename it to X", \
"a getter for X". A sentence that gives no name comes back unchanged, word for \
word.

Return only the text.

text: add a rust function called read config file
add a rust function called read_config_file

text: call it max retries in python
call it max_retries in python

text: rename the typescript variable to retry count
rename the typescript variable to retryCount

text: une classe qui s'appelle lecteur audio
une classe qui s'appelle LecteurAudio

text: the retry count is too high and it hammers the api
the retry count is too high and it hammers the api

text: we talked about python packaging for most of the afternoon
we talked about python packaging for most of the afternoon
"""

# v4 — the prompt stops rewriting anything.
#
# Everything in this feature is deterministic except one judgement: which words
# are the name, when no marker announces them. The casing is a function, the
# convention is a lookup off the language word, and the substitution is a
# string replace. v3 got spans roughly right and conventions wrong — it
# answered camelCase where python wants snake, and dropped words it was not
# asked to touch — which is what asking a model to return a whole rewritten
# sentence buys you.
#
# So it answers with the name and nothing else, and code does the rest. Scored
# that way too: SPAN_ONLY variants are run through the same casing and
# substitution the script uses.
VARIANTS["v4"] = """\
The text is a dictated sentence. Some of them give a name to a function, a \
variable, a class or a constant.

Reply with just those words, copied from the sentence, and nothing else. \
Or reply NO NAME.

- Copy the words exactly as they appear. Do not rewrite them, join them or \
change their case — that is done elsewhere.
- A name is two to four words. Take the whole name and only the name.
- The name may be given without the word "called": "call it X", "rename it to \
X", "a getter for X".
- Reply NO NAME when the sentence names nothing — when it merely talks about a \
function, a class or a variable, or is about something else entirely.

text: add a rust function called read config file
read config file

text: call it max retries in python
max retries

text: rename the typescript variable to retry count
retry count

text: the retry count is too high and it hammers the api
NO NAME

text: we talked about python packaging for most of the afternoon
NO NAME

text: there is a method called cognitive behavioural therapy for that
NO NAME
"""

# Variants that answer with the name alone. The casing, the convention and the
# substitution are code — see `place`.
SPAN_ONLY = {"v4"}

def place(span, text):
    """The sentence with `span` cased and put back — the deterministic half,
    shared with examples/identifiers.py so both are scored on one algorithm."""
    span = span.strip().strip('".')
    if not span or re.search(r"\bno name\b|\bnone\b", span, re.I):
        return text
    words = [w for w in re.split(r"[^\w'’]+", span) if w]
    if len(words) < 2 or len(words) > 4:
        return text
    # Only if the model copied words that are actually there.
    if span.lower() not in text.lower():
        return text
    start = text.lower().index(span.lower())
    before = text[:start]
    return text[:start] + cased(words, style_for(text, before)) + text[start + len(span):]

# --- the control -----------------------------------------------------------
#
# No model: examples/identifiers.py, imported rather than reimplemented. It was
# a copy of these rules until the copies could disagree — and a runner scoring
# its own version of an algorithm answers a question about code nobody runs.
sys.path.insert(0, str(ROOT / "examples"))
import identifiers as shipped  # noqa: E402

cased = shipped.cased
style_for = shipped.style_for
control = shipped.convert

# --- PromptRunner.clean, ported --------------------------------------------

def clean(raw):
    text = raw.strip()
    if text.startswith("```"):
        lines = text.split("\n")[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        text = "\n".join(lines).strip()
    if "\n" in text:
        first, rest = text.split("\n", 1)
        first = first.strip()
        if first.endswith(":") and len(first) < 60 and not first.startswith("-"):
            text = rest.strip()
    if len(text) >= 2 and text.startswith('"') and text.endswith('"'):
        text = text[1:-1]
    return text

def ask(model, system, user, predict, meter=None):
    body = {"model": model, "system": system, "prompt": user, "stream": False,
            "think": False,
            "options": {"temperature": 0, "num_predict": predict}}
    req = urllib.request.Request(
        "http://localhost:11434/api/generate",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    started = time.time()
    with urllib.request.urlopen(req, timeout=600) as response:
        payload = json.load(response)
    if meter is not None:
        for key in ("prompt_eval_count", "eval_count",
                    "prompt_eval_duration", "eval_duration"):
            meter[key] = meter.get(key, 0) + (payload.get(key) or 0)
        meter["calls"] = meter.get("calls", 0) + 1
    return clean(payload.get("response") or ""), time.time() - started

def same(a, b):
    """Compared as the user would see it: whitespace normalised, case and
    punctuation not — the casing IS the answer here."""
    def norm(text):
        return " ".join(unicodedata.normalize("NFC", text).split())
    return norm(a) == norm(b)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--variant", default="v1", choices=sorted(VARIANTS))
    ap.add_argument("--predict", type=int, default=128)
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--cases", default=str(CASES))
    ap.add_argument("--code-only", action="store_true",
                    help="no model at all: a regex for the naming phrase, cased in code")
    ap.add_argument("--combo", action="store_true",
                    help="the shipped shape: the script first, and the prompt only on what it"
                         " declined — which is what makes the model call rare enough to afford")
    ap.add_argument("--script", default=None,
                    help="score a `command:` transform instead — the same way the app runs it,"
                         " the transcript on stdin and the rewrite on stdout")
    args = ap.parse_args()

    cases = yaml.safe_load(pathlib.Path(args.cases).read_text())["cases"]
    system = VARIANTS[args.variant]
    meter = {}
    if not args.code_only and not args.script:
        ask(args.model, system, "warm up", args.predict)

    scores = {"change": [0, 0], "keep": [0, 0]}
    by_category = {}
    failures = []
    elapsed = 0.0
    for case in cases:
        text = str(case["input"])
        want = str(case.get("expect", text))
        kind = case["kind"]

        if args.combo:
            started = time.time()
            got = control(text)
            # The model is asked only when the deterministic half found
            # nothing. On a transcript with a marker in it — the common case —
            # nothing is paid at all.
            if got == text:
                reply, _ = ask(args.model, system, text, args.predict, meter)
                got = place(reply, text)
            dt = time.time() - started
        elif args.script:
            started = time.time()
            done = subprocess.run([args.script], input=text, capture_output=True, text=True)
            got, dt = done.stdout.rstrip("\n"), time.time() - started
            if done.returncode != 0:
                got = text  # the app keeps the transcript when a command fails
        elif args.code_only:
            got, dt = control(text), 0.0
        else:
            got, dt = ask(args.model, system, text, args.predict, meter)
            if args.variant in SPAN_ONLY:
                got = place(got, text)
        elapsed += dt

        ok = same(got, want)
        scores[kind][0] += ok
        scores[kind][1] += 1
        category = case.get("category", kind)
        tally = by_category.setdefault(category, [0, 0])
        tally[0] += ok
        tally[1] += 1
        if not ok:
            failures.append((kind, case["name"], got, want))
        if args.verbose:
            print(f"  {'✓' if ok else '✗'} {dt:5.2f}s {case['name']}")

    total = sum(v[1] for v in scores.values())
    passed = sum(v[0] for v in scores.values())
    print(f"\n{args.model}  variant={args.variant}  ({len(cases)} cases)")
    for kind in ("change", "keep"):
        got, n = scores[kind]
        note = "  <- where this design lives or dies" if kind == "keep" else ""
        print(f"  {kind:8} {got}/{n} = {100*got/n:.0f}%{note}")
    print(f"  overall  {passed}/{total} = {100*passed/total:.0f}%")
    print(f"  {elapsed/total:.2f}s avg")
    if meter.get("calls"):
        c = meter["calls"]
        print(f"  tokens   {meter['prompt_eval_count']/c:.0f} in, {meter['eval_count']/c:.0f} out per call")
    print("  by category:")
    for category, (got, n) in sorted(by_category.items()):
        print(f"    {category:16} {got}/{n}")
    if failures:
        print("  failures:")
        for kind, name, got, want in failures:
            print(f"    [{kind}] {name}\n      got  {got!r}\n      want {want!r}")

main()

# --- Scoreboard, and what it decided ---------------------------------------
#
# 70 cases: 38 change, 32 keep. The set grew twice, both times with cases
# written to break what was passing rather than to flatter it.
#
#                              change  keep  overall  latency
#     examples/identifiers.py    87%   94%    90%     0.03s  <- ships, by default
#     v4, the prompt as a span   97%   88%    93%     1.03s
#     script then v4 on the rest 100%  81%    91%     0.51s
#     v2, the prompt rewriting   58%   83%    68%     1.15s
#     v3, v2 aimed at no-marker  48%   87%    64%     1.1s
#
# Read the keep column, not the overall. This runs on every transcript in its
# pipeline, so a missed naming costs one rewrite you do by hand and a wrong one
# costs a sentence you have to notice and undo.
#
# THE PROMPT'S JOB, AFTER THE DETERMINISTIC PARTS WERE NAMED. v2 and v3 return
# the rewritten sentence and are hopeless at it — they answer camelCase where
# python wants snake, capitalise "python" to "Python", drop articles, translate
# French names into English. But casing is a function, the convention is a
# lookup off the language word, and putting the name back is a string replace.
# All of that is code. What is left is one judgement: which words are the name,
# when nothing announces them.
#
# v4 asks only that, and answers with the words. On the eight cases with no
# marker — "call it max retries", "rename the variable to retry count", "a
# getter for the user profile name" — the script scores 2/8 by construction,
# v2 scored 2/8, v3 5/8, and v4 scores 8/8. Same model, same cases; the
# difference is entirely what it was asked for.
#
# WHY THE COMBINATION IS NOT WHAT SHIPS, despite scoring 100% on change. Run
# the script first and ask the model only about what it declined, and the model
# sees exactly the sentences a conservative rule refused — which are
# disproportionately the near-misses. Keep falls from 94% to 81%: chaining a
# permissive fallback behind a careful rule inverts the care. It is the right
# option for someone who dictates code all day and will notice; it is the wrong
# default.
#
# So the script ships in the default pipeline, gated twice — `app:` to the
# editors and terminals, `when:` to a sentence containing a kind word, so no
# process starts on prose. v4 is kept here, measured, for anyone who wants the
# other trade.
#
# WHAT IT COSTS AS A DEFAULT, stated rather than buried. One case in 70 is a
# sentence it rewrites and should not: "there is a method called cognitive
# behavioural therapy for that". Three plausible words after a kind word and a
# naming word, and no surface rule tells them from a name — a length cap
# already removed the five others of that shape ("the class called intro to
# python starts at nine tomorrow"). The other five failures are namings it
# declines, which leave the transcript exactly as dictated.
#
# CAUTIONS. The script's stop lists and its four-word cap were tuned on cases
# now in this set, so its 90% is not a held-out number; the honest ones were
# 93% and 88% on the two batches written afterwards. The next change needs new
# cases again. And the runner imports examples/identifiers.py rather than
# reimplementing it, so `--code-only` and `--script` score the same file the
# app writes — scripts/check-example-script.sh is what keeps the shipped copy
# equal to it.
