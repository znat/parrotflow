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
import argparse, json, re, sys, time, unicodedata, urllib.request, pathlib

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

# --- the control -----------------------------------------------------------
#
# No model: find the naming phrase, take the words after it, case them. This
# is a real candidate implementation, not a floor invented to be beaten.

# The naming phrase, and the kind word that has to precede it. Requiring the
# kind word is not tidiness: without it "i called max yesterday" is a name
# being introduced, and the transform renames a person.
KIND = re.compile(
    r"\b(?:function|method|variable|class|constant|type|struct|interface|enum|"
    r"fonction|m[ée]thode|variable|classe|constante)\b", re.I)
# "called by the scheduler" is a passive and never a naming, which is the one
# held-out case the control failed before this lookahead.
TRIGGER = re.compile(
    r"\b(?:called|named|call it|nomm[ée]e?|qui s['’]appelle|appel[ée]e?)\s+"
    r"(?!by\b|par\b)", re.I)
SNAKE_LANGUAGES = re.compile(r"\b(?:python|rust|ruby|elixir)\b", re.I)
PASCAL_KIND = re.compile(r"\b(?:class|classe|type|struct|interface|enum)\b", re.I)
SCREAMING_KIND = re.compile(r"\b(?:constant|constante)\b", re.I)
# Where the name stops and the sentence goes on again.
# Words that end the name. "in", "from", "on" and "to" were in this list and
# had to come out: they are ordinary parts of identifiers — "is logged in",
# "build request from config" — and stopping there truncated the name. What is
# left is the words that only ever resume the sentence.
TAIL = re.compile(
    r"\b(?:that|which|for|and|so|should|will|when|if|because|"
    r"qui|que|pour|et|dans|sur|avant|apr[èe]s|doit)\b", re.I)

def case_of(sentence, before):
    if SCREAMING_KIND.search(before):
        return "screaming"
    if PASCAL_KIND.search(before):
        return "pascal"
    if SNAKE_LANGUAGES.search(sentence):
        return "snake"
    return "camel"

def cased(words, style):
    if style == "snake":
        return "_".join(w.lower() for w in words)
    if style == "screaming":
        return "_".join(w.upper() for w in words)
    if style == "pascal":
        return "".join(w.capitalize() for w in words)
    return words[0].lower() + "".join(w.capitalize() for w in words[1:])

def control(text):
    """What the app would do with no model in the loop."""
    out = text
    for match in list(TRIGGER.finditer(text))[::-1]:
        # Only a name that was introduced as one.
        if not KIND.search(text[:match.start()]):
            continue
        rest = text[match.end():]
        stop = TAIL.search(rest)
        span = rest[:stop.start()] if stop else rest
        words = [w for w in re.split(r"[^\w'’]+", span) if w]
        if len(words) < 2:
            continue
        style = case_of(text, text[:match.start()])
        replaced = cased(words, style)
        out = out.replace(span.strip(), replaced, 1) if span.strip() in out else out
    return out

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
    args = ap.parse_args()

    cases = yaml.safe_load(pathlib.Path(args.cases).read_text())["cases"]
    system = VARIANTS[args.variant]
    meter = {}
    if not args.code_only:
        ask(args.model, system, "warm up", args.predict)

    scores = {"change": [0, 0], "keep": [0, 0]}
    by_category = {}
    failures = []
    elapsed = 0.0
    for case in cases:
        text = str(case["input"])
        want = str(case.get("expect", text))
        kind = case["kind"]

        if args.code_only:
            got, dt = control(text), 0.0
        else:
            got, dt = ask(args.model, system, text, args.predict, meter)
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
# 56 cases: 33 change, 23 keep.
#
#                          change  keep  overall  latency
#     no model at all       100%   100%   100%      —
#     gemma4:e4b  v1         58%    83%    68%    0.97s
#     gemma4:e4b  v2         58%    83%    68%    1.15s
#     granite4:3b v2         39%    78%    55%    0.49s
#
# The control wins by thirty-two points and costs nothing, so the prompt-only
# design is dead. What matters more than the gap is its shape. The model's
# failures are not near misses:
#
#     "a python function called max retries"  -> "...called maxRetries"
#     "a python class called user service"    -> "a Python class called ..."
#     "swift function named ..."              -> "Swift function named ..."
#     "une variable qui s'appelle nom utilisateur" -> "... userName"
#     "... for the settings page"             -> "... for the settingsPage"
#
# It gets the convention wrong, it capitalises language names nobody asked it
# to touch, it adds articles, and on the French cases it translates the name
# into English. That last one is disqualifying on its own: a transform that
# runs on every transcript and silently rewrites words outside its remit is
# not something you can leave switched on, whatever it scores.
#
# v2's examples changed nothing at all — same 38/56, the same failures. When
# two genuinely different prompts land on the same number you are measuring the
# model, not the prompt, and no wording was going to close a thirty-point gap.
#
# So the answer is not "a better prompt" and not the two-stage design either.
# The two-stage was meant to leave the model the job of *finding* the names —
# but a spoken name announces itself with a literal marker ("a python function
# called ..."), so there is nothing to find. The model was never needed for
# either half.
#
# What that leaves is a `replace:` table, which is config, plus the one thing
# the substitution engine cannot do: change the case of a captured group. A
# `$1|snake` / `$1|camel` / `$1|pascal` / `$1|screaming` operator is generic —
# every transform anyone writes gets it — and it is the only code this feature
# needs. The rest is lines in config.yaml, out of the default pipeline.
#
# Two cautions for whoever picks this up. The control's stop list and its
# "a kind word must precede the naming phrase" rule were tuned on the first 41
# cases; the last 15 were written afterwards and are what the 93% before the
# passive fix was measured on. Both halves are one set now, so the next change
# needs new held-out cases or its number means nothing. And the shape the
# control still cannot see is a name with an ordinary word on both sides of the
# boundary — the same limit `dotted` documents, for the same reason.
