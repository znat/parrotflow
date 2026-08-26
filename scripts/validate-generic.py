#!/usr/bin/env python3
"""Score a *generic* transform prompt against tests/generic-cases.yaml.

    scripts/validate-generic.py gemma4:e4b
    scripts/validate-generic.py gemma4:e4b --variant v3 --verbose
    scripts/validate-generic.py none --code-only      # the no-model control
    scripts/validate-generic.py gemma4:e4b --shipped  # today's narrow prompts

The question: if the router matches nothing, can one prompt be handed the
whole instruction and trusted to do it? Nothing is implemented yet — this is
the measurement that decides whether it should be.

Variants live in this file so they can be compared directly. The composition
and the cleanup are ports of PromptRunner.compose/clean, so the number
describes the pipeline the app would actually run, not an approximation of it.

Two scores, because the two halves fail differently. `change` cases ask for an
edit and score it exactly. `keep` cases must come back byte for byte — the
instruction does not apply, or is not an instruction. A generic prompt has no
subject to anchor it and no wrong-tool signal behind it, so `keep` is where
this design either survives or does not.

Scoreboard and what it decided: the notes at the bottom of this file.
"""
import argparse, json, subprocess, sys, time, urllib.request, pathlib

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")

ROOT = pathlib.Path(__file__).resolve().parent.parent
CASES = ROOT / "tests" / "generic-cases.yaml"
BIN = ROOT / ".build" / "release" / "ParrotFlow"

# --- prompt variants -------------------------------------------------------
#
# Each is what would become the built-in fallback prompt's `content`. The
# instruction and the text are handed over the same way a configured prompt
# gets them: content as the system message, "instruction: ... text: ..." as
# the user message.

VARIANTS = {}

# v1 — the rules and nothing else. The obvious first try, and the baseline
# every later variant has to beat.
VARIANTS["v1"] = """\
Apply the instruction to the text.

Make exactly the change the instruction asks for, and no other. Every word
the instruction does not mention comes back as it was — same wording, same
order, same capitalisation, same punctuation.

If the instruction does not apply to this text, return the text unchanged.

Return only the text.
"""

# v2 — v1 plus the rule that the instruction is an edit, never a question.
# The router used to absorb idle sentences by answering NONE; under a fallback
# they arrive here instead, so this is the class the design adds.
VARIANTS["v2"] = """\
Apply the instruction to the text.

Make exactly the change the instruction asks for, and no other. Every word
the instruction does not mention comes back as it was — same wording, same
order, same capitalisation, same punctuation.

The instruction is an edit to make, never a question to answer and never a
remark to reply to. Return the text unchanged when the instruction asks for
something the text does not contain, when the text is already in the form it
asks for, and when it is not an instruction at all.

Return only the text.
"""

# v3 — v2 plus worked examples: one edit, one already-in-the-form, one idle
# sentence. Examples beat rules elsewhere in this repo; this is that bet.
VARIANTS["v3"] = """\
Apply the instruction to the text.

Make exactly the change the instruction asks for, and no other. Every word
the instruction does not mention comes back as it was — same wording, same
order, same capitalisation, same punctuation.

The instruction is an edit to make, never a question to answer and never a
remark to reply to. Return the text unchanged when the instruction asks for
something the text does not contain, when the text is already in the form it
asks for, and when it is not an instruction at all.

instruction: write the numbers as digits
text:
we saw about forty of them
we saw about 40 of them

instruction: make the dates ISO
text:
the release is 2026-02-01
the release is 2026-02-01

instruction: how long is that going to take
text:
the migration runs on friday
the migration runs on friday

Return only the text.
"""

# v4 — v3, but the no-op answer is a token instead of a copy of the input.
#
# The reasoning is the one from the spelling extractor: "return it unchanged"
# asks the model to reproduce the text verbatim, and verbatim copying is the
# thing small models are worst at. Every keep failure so far is a model that
# decided correctly and then edited while retyping (150 cm -> 1.5 m, the
# fifteenth -> the 15th). A token lets code do the copying.
VARIANTS["v4"] = """\
Apply the instruction to the text.

Make exactly the change the instruction asks for, and no other. Every word
the instruction does not mention comes back as it was — same wording, same
order, same capitalisation, same punctuation.

The instruction is an edit to make, never a question to answer and never a
remark to reply to.

Reply with exactly UNCHANGED, and nothing else, when the instruction asks for
something the text does not contain, when the text is already in the form it
asks for, or when it is not an instruction at all.

instruction: write the numbers as digits
text:
we saw about forty of them
we saw about 40 of them

instruction: make the dates ISO
text:
the release is 2026-02-01
UNCHANGED

instruction: how long is that going to take
text:
the migration runs on friday
UNCHANGED

Otherwise return only the text.
"""

# v5 — v3 with one edit: the worked example is a properly punctuated sentence.
# v3 and v4 both dropped the full stop off grammar fixes that v1 and v2 got
# right, and the only thing they added was an example written without one.
# v6 = v3 plus two examples for a correction — an instruction with the
# imperative taken out. v3 scored 3/6 on them and failed in one particular way:
# handed "no I meant three of them", it edited *the instruction* and returned
# that, having read the corrective phrasing as prose and so as the subject. The
# pair teaches both halves at once, which is what the existing three examples
# already do for questions.
VARIANTS["v6"] = VARIANTS["v3"].replace(
    "Return only the text.",
    """instruction: I meant Tuesday
text:
the meeting is on Monday
the meeting is on Tuesday

instruction: this is not what I had in mind
text:
the migration runs on friday
the migration runs on friday

Return only the text.""",
)

VARIANTS["v5"] = VARIANTS["v3"].replace(
    "we saw about forty of them\nwe saw about 40 of them",
    "We saw about forty of them.\nWe saw about 40 of them.",
)

# --- the pipeline, ported from PromptRunner --------------------------------


def compose(content, instruction, text):
    instruction = instruction.strip()
    if not instruction:
        return content, text
    return content, "instruction: {}\n\ntext:\n{}".format(instruction, text)


def token_budget(text):
    return max(256, (len(text) // 4) * 2)


def clean(raw):
    """Port of PromptRunner.clean — strips wrapping, never edits the text."""
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


def ask(model, system, user, budget, endpoint="http://localhost:11434"):
    """The same request LocalLLM.complete makes — /api/generate, thinking off.

    Not a detail. The first version of this used /api/chat with thinking left
    on, and gemma spent the whole num_predict budget reasoning and returned an
    empty answer on a third of the set. The score that produced (22/38) was
    measuring a request the app never sends.
    """
    body = {
        "model": model,
        "system": system,
        "prompt": user,
        "stream": False,
        "think": False,
        "options": {"temperature": 0, "num_predict": budget},
        "keep_alive": "24h",
    }
    request = urllib.request.Request(
        endpoint + "/api/generate",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        payload = json.load(response)
    return payload["response"]


def shipped_prompt_for(category):
    """The narrow prompt the app ships today for this category, if any."""
    return {"digits": "digits", "dates": "dates", "grammar": "grammar"}.get(category)


def run_shipped(name, instruction, text):
    result = subprocess.run(
        [str(BIN), "--prompt", name, instruction, text, "--quiet"],
        capture_output=True, text=True,
    )
    return result.stdout.strip().split("\n")[-1] if result.stdout.strip() else ""


# --- scoring ---------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model")
    parser.add_argument("--variant", default="v1")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--code-only", action="store_true",
                        help="the control: return the text unchanged, no model")
    parser.add_argument("--shipped", action="store_true",
                        help="run the narrow prompts on the cases they cover")
    parser.add_argument("--app", action="store_true",
                        help="run the built-in through the binary, not this file's port")
    parser.add_argument("--only", default=None, help="one category")
    args = parser.parse_args()

    cases = yaml.safe_load(CASES.read_text())["cases"]
    if args.only:
        cases = [c for c in cases if c["category"] == args.only]
    if args.shipped:
        cases = [c for c in cases if shipped_prompt_for(c["category"])]

    content = VARIANTS[args.variant]
    results = []
    elapsed = 0.0

    for case in cases:
        text = case["input"]
        want = [case["expect"]] if case["kind"] == "change" else [text]
        want += case.get("accept", [])

        started = time.time()
        if args.code_only:
            got = text
        elif args.app:
            # The one number that is not an approximation: FreeForm.prompt as
            # Swift holds it, composed and cleaned by PromptRunner. Everything
            # else here is a port, and a port is exactly how a validation set
            # drifts into scoring code nobody runs.
            got = run_shipped("anything", case["instruction"], text)
        elif args.shipped:
            got = run_shipped(shipped_prompt_for(case["category"]),
                              case["instruction"], text)
        else:
            system, user = compose(content, case["instruction"], text)
            got = clean(ask(args.model, system, user, token_budget(text)))
            # The sentinel is the app's job to resolve, not the model's: it
            # means "nothing here changes", and the text it stands for is the
            # text we already have. Parsed loosely — a model that answers
            # "UNCHANGED." has decided right and punctuated badly.
            if got.strip().strip(".").upper() == "UNCHANGED":
                got = text
        elapsed += time.time() - started

        ok = any(got.strip() == w.strip() for w in want)
        results.append((case, got, ok))

        if ok:
            if args.verbose:
                print("  ✓ {:<34} {}".format(case["name"], case["category"]))
        else:
            if case["kind"] == "keep":
                # Two ways to fail a keep, and they are not equally bad. Text
                # that came back edited is text the speaker loses; text that
                # came back as prose is the model answering instead of editing.
                mark = ("answered instead of editing"
                        if len(got) > len(text) * 1.6 or not got
                        else "touched text that needed nothing")
            elif got.strip() == text.strip():
                mark = "did nothing"
            else:
                mark = "wrong edit"
            print("  ✗ {:<34} ({})".format(case["name"], mark))
            print('      say   "{}"'.format(case["instruction"]))
            print("      in    {}".format(text.replace("\n", " ⏎ ")))
            print("      got   {}".format(got.replace("\n", " ⏎ ")))
            print("      want  {}".format(want[0].replace("\n", " ⏎ ")))

    def tally(subset):
        return sum(1 for _, _, ok in subset if ok), len(subset)

    changes = [r for r in results if r[0]["kind"] == "change"]
    keeps = [r for r in results if r[0]["kind"] == "keep"]

    label = ("control (no model)" if args.code_only
             else "the built-in, through the app" if args.app
             else "narrow prompts" if args.shipped
             else "{} {}".format(args.model, args.variant))
    print()
    print("  {}".format(label))
    print("  {}/{} overall   {}/{} change   {}/{} keep   {:.2f}s/case".format(
        *tally(results), *tally(changes), *tally(keeps),
        elapsed / max(1, len(results))))

    by_category = {}
    for case, _, ok in results:
        hit, total = by_category.get(case["category"], (0, 0))
        by_category[case["category"]] = (hit + (1 if ok else 0), total + 1)
    print("  " + "   ".join("{} {}/{}".format(name, hit, total)
                            for name, (hit, total) in sorted(by_category.items())))
    return 0 if all(ok for _, _, ok in results) else 1


if __name__ == "__main__":
    sys.exit(main())


# --- scoreboard ------------------------------------------------------------
#
# 38 cases: 27 `change`, 11 `keep`. Latency is warm, per case.
#
#                            overall   change    keep   latency
#     gemma4:12b  v3          35/38     25/27   10/11    3.14s
#     gemma4:e4b  v3          32/38     24/27    8/11    1.15s  <- best of size
#     --app (v3 as shipped)   32/38     24/27    8/11    1.22s  <- FreeForm.swift
#     gemma4:e4b  v1          31/38     24/27    7/11    0.92s
#     gemma4:e4b  v2          31/38     24/27    7/11    0.97s
#     gemma4:e4b  v4          31/38     23/27    8/11    1.14s  UNCHANGED token
#     gemma4:e4b  v5          31/38     24/27    7/11    1.16s
#     granite4:3b v3          30/38     22/27    8/11    0.38s
#     (no model, text as-is)  11/38      0/27   11/11      -    <- the control
#
# The `--app` row is the one that is not an approximation: the same 38 cases
# through FreeForm.prompt as Swift holds it, composed and cleaned by
# PromptRunner. It matches this file's port case for case and category for
# category, which is the only evidence that the port has not drifted — and this
# repo has had that drift twice before, worth 31 points once.
#
# Read the flatness first. Five genuinely different prompts on gemma4:e4b
# land within one case of each other, which by the usual tell means the
# prompt is not the variable — the model is. v3 repeated 32/38 with an
# identical category breakdown on a second run, so that one case is a real
# difference and not noise, but it is the whole spread.
#
# What the variants were, and what each was worth:
#
#     v1  rules only                                31/38
#     v2  + "an edit, never a question to answer"   31/38  traded one for one
#     v3  + three worked examples                   32/38  <- best
#     v4  v3 with UNCHANGED instead of a copy       31/38
#     v5  v3 with a punctuated example              31/38
#
# v2 is the clean illustration of why this is measured: the rule it adds is
# obviously right, it fixed the idle question it was written for, and it paid
# for that by appending "$0.00" to a sentence with no money in it. Net zero.
#
# v4 is the one worth not re-proposing. Everywhere else in this repo a null
# answer wants a token — silence makes a model invent something — and the
# reasoning transfers cleanly: "return it unchanged" asks a small model to
# copy text back verbatim, which is what it is worst at, and every keep
# failure was a model deciding right and then editing while retyping
# (150 cm -> 1.5 m). It works, and it costs more than it saves: the sentinel
# took money to 6/6 and lost two grammar cases, because a prompt whose
# examples end in a bare token stops returning terminal punctuation. v5 tried
# to buy that back with a punctuated example and only moved which grammar
# case failed.
#
# Against the narrow prompts the app ships today, on the 16 cases they cover
# (--shipped):
#
#     shipped narrow prompts   12/16      dates 2/6   digits 5/5  grammar 5/5
#     generic v3, same cases   14/16      dates 5/6   digits 5/5  grammar 4/5
#
# So `digits` is pure duplication — one prompt, five cases, no difference —
# and `dates` is worse than generic, not better: it answers "the deadline is
# March 3 2026" with "2026-03-03", dropping the sentence around the date. A
# narrow prompt sees one subject and reaches for it; the generic prompt has
# no subject and leaves everything it was not asked about alone.
#
# The failures that survive every variant are three kinds, and none is a
# wording problem:
#
#   - underdetermined instructions. "spell the month out" on 2026-01-15 does
#     not say where the day goes, and gemma answers "2026-January-15".
#   - already in the form asked for, where the form is fuzzy. "convert that
#     to metric" on "150 cm" gives "1.5 m" on every variant and every model
#     below 12b. Exact ISO dates it leaves alone; a unit it cannot.
#   - reach. "capitalise the product names" also capitalises the first word,
#     or shouts (SUPABASE). It is the grammar prompt's failure mode without
#     the grammar prompt's rules against it.
#
# gemma4:12b is the only model that clears these, at 35/38 and 10/11 on keep
# — and it fails in the direction that costs most, rewriting "it works, and
# it works well" into em dashes. Three times the latency to be better at the
# task and worse at restraint is not a trade this feature wants.
#
# granite4:3b is a third of the size and a third of the latency for two
# cases, which is the same shape as the spelling set and makes it the model
# to reach for if latency ever matters more than it does now. It cannot do
# the routing gate below, so it would have to be the transform model only.
#
# --- the gate --------------------------------------------------------------
#
# The generic prompt's worst failures are idle sentences: "what is the
# weather tomorrow" arriving with text selected, and coming back as an edit
# to that text. A fallback hung off the router's NONE inherits all of them,
# because NONE means both "not an edit" and "an edit with no tool".
#
# Two ways to separate those were measured before deciding anything.
#
# Adding the generic prompt to the catalogue as an ordinary entry does not
# work. With `anything — any other change to the text` in the list, gemma
# picked it zero times out of ten: free-form edits went to NONE, and two went
# to the wrong narrow tool ("format the amounts as dollars" -> digits, "use
# the 24 hour clock" -> dates). An abstract description cannot compete with
# concrete ones.
#
# Giving the router a third answer does work — ANY for "an edit, but no tool
# does it", NONE reserved for "not an edit at all". On gemma4:e4b, 18/19: all
# nine free-form edits to ANY, five of six idle sentences to NONE, and every
# narrow tool still won its own instruction. The one failure is the familiar
# one, a tool name used as an ordinary noun ("the terse version was better").
# Notably "I bought a box of bullets" — the case Router.swift documents as
# the model's floor — passes here, so the extra answer costs the existing
# routing nothing and appears to help it.
#
# granite4:3b scores 6/19 on the same gate and collapses everything into
# `bullets`. Three-way routing is a gemma-class job.

# --- 2026-08-26: corrections -------------------------------------------------
#
# Six cases added for a *correction* — an instruction with the imperative taken
# out. "make it Tuesday" and "I meant Tuesday" ask for the same edit, and the
# second is what people say to a machine that has just written their own
# sentence down. Four ask for the edit; two are the phrase with no edit behind
# it, which is the reason the category needed negatives: "I meant" is not a
# marker. It introduces an edit only when it names the replacement, and bare it
# is a complaint.
#
#   gemma4:e4b-mlx v3 (shipped)   37/44   corrections 3/6
#   gemma4:e4b-mlx v6             39/44   corrections 5/6
#
# v6 is v3 plus two examples, one of each kind. Every other category is
# identical between them, so the two points are the corrections and nothing
# else. v6 shipped.
#
# The failure v3 had is worth keeping in mind, because it is not the one you
# would guess: handed "no I meant three of them" it edited *the instruction*
# and returned that. Corrective phrasing reads as prose, and prose in the
# instruction slot reads as the subject.
#
# That case still fails on v6, and is left standing. Fixing one case with a
# third example is tuning on the set — it wants fresh cases first.
#
# The runner's default is v1, which has never been what ships. v3 was the
# shipped prompt before this and v6 is now; check which one matches
# FreeForm.swift before reading any number here as a statement about the app.
