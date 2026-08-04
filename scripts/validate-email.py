#!/usr/bin/env python3
"""Score the `email` prompt against examples/transforms/email/cases.yaml.

    scripts/validate-email.py gemma4:e4b                  # what ships today
    scripts/validate-email.py gemma4:e4b --variant v7
    scripts/validate-email.py gemma4:e4b --variant v7 --verbose
    scripts/validate-email.py gemma4:e4b --all            # every variant, in order

The prompt lays dictated text out as an email. It is the riskiest step in the
pipeline for one reason: it returns the whole text, it runs without being asked
for, and what it invents — a greeting, a closing word, a name — is exactly the
part a sender does not re-read. So the set is scored in two halves and the
restraint half is the one that decides a variant.

`shipped` is read out of config.example.yaml rather than copied into this file,
so the number always describes the prompt the app actually installs. Candidate
variants live below, with their scores, including the ones that lost.

The request is the one LocalLLM.complete makes — /api/generate, thinking off,
temperature 0 — and `clean` is a port of PromptRunner.clean. A pipeline prompt
gets no instruction, so the transcript is the whole user message.

Scoreboard and what it decided: the notes at the bottom of this file.
"""
import argparse, json, re, sys, time, urllib.request, pathlib

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")

ROOT = pathlib.Path(__file__).resolve().parent.parent
CASES = ROOT / "examples" / "transforms" / "email" / "cases.yaml"
EXAMPLE_CONFIG = ROOT / "config.example.yaml"

# --- prompt variants -------------------------------------------------------
#
# Each is a candidate `prompt:` body for the `email` transform. `shipped` is
# not here on purpose — it is read from config.example.yaml.

VARIANTS = {}

# v7 — the signature rule turned around to say what the email *ends with*.
#
# v6 (shipped) states the rule as a pair of conditions: "A name at the end is a
# signature ... No name at the end means no signature". The second half is a
# prohibition, and this prompt's own history says prohibitions here are read as
# topics rather than as limits — v1's "if none was dictated, do not invent one"
# produced an invented greeting, and v3's "Nothing is ever deleted" produced a
# literal "[Signature]". The fix that worked for the greeting in v2 was to turn
# the rule around and say what the email starts with when no hello was spoken.
# This does the same at the other end, and adds the one clause the failure
# needs outright: a name that was not spoken is not available to be written,
# in brackets or otherwise.
VARIANTS["v7"] = """\
Lay the text out as an email, in the language it was dictated in.
Fix the writing; do not write it.

Correct grammar, spelling and punctuation, and drop the hesitations
— um, uh, euh, well, you know, I mean. Every other word survives:
the wording, the order and the tone are the speaker's.

If the text opens with a greeting, it goes on its own line, with a
comma after it and a blank line under it. If it does not, the email
starts with the first sentence. Never add a greeting nobody spoke.

Break the body into paragraphs where the subject changes, a blank
line between them. Add no headings and no emphasis.

Three or more things listed in a row never stay inline. Whatever
joined them — commas, "and", nothing at all — the words introducing
them take a colon and each thing goes on a line of its own behind a
dash. No number has to be said for this: "here is what I need from
you", "the steps are", "we should" all open a list as surely as
"there are three things" does. Two things are a sentence and stay
one.

The email ends on the last thing the speaker said. If that last
thing is a name, it is a signature: a blank line, then the name on
its own line, and a closing word said just before it — thanks,
merci — on the line above. If it is anything else — a question, a
goodbye, a sentence — that is the last line, and there is nothing
under it. The only name that can appear is one that was spoken; an
unspoken one has no stand-in, in brackets or otherwise.

A short reply is not an email with parts. One or two sentences and
no hello in front of them come back as one or two sentences,
corrected, with no line put anywhere.

Return only the email.
"""

# v8 — v7, plus the closing word cut loose from the name.
#
# v7's signature clause still reaches the closing word only through the name
# ("a closing word said just before it"), which leaves "can you review the
# draft thanks" — a spoken thanks with nobody signing — describing a case the
# prompt has no line for. This says what happens to a closing word on its own.
VARIANTS["v8"] = VARIANTS["v7"].replace(
    """merci — on the line above. If it is anything else — a question, a
goodbye, a sentence — that is the last line, and there is nothing
under it. The only name that can appear is one that was spoken; an
unspoken one has no stand-in, in brackets or otherwise.""",
    """merci — on the line above. If it is anything else — a question, a
goodbye, a closing word with nobody signing after it, a sentence —
that is the last line, and there is nothing under it. The only name
that can appear is one that was spoken; an unspoken one has no
stand-in, in brackets or otherwise.""",
)


# v9 — counting out loud opens a list, however the items are punctuated.
#
# v7's list rule only describes things "listed in a row" — joined by commas or
# "and" inside one sentence — and every example in it is a noun phrase. A
# speaker who counts ("one, ... two, ... three, ...") in separate sentences
# matches none of it, so nothing fires; and because the ordinals are not part
# of what the sentence says, they get dropped on the way past. Both halves of
# that are wrong, and the deletion is the worse half.
#
# The prompt's history says a version that forced ordinals "dropped an item on
# the floor", so this says the count is the thing to preserve and the items are
# what it counts. The two negatives it has to survive are "first thing in the
# morning" and "the one I meant" — the words used as ordinary language rather
# than as counting — which is why the rule is written about a speaker counting
# rather than about the words themselves.
VARIANTS["v9"] = VARIANTS["v7"].replace(
    """Three or more things listed in a row never stay inline. Whatever
joined them — commas, "and", nothing at all — the words introducing
them take a colon and each thing goes on a line of its own behind a
dash. No number has to be said for this: "here is what I need from
you", "the steps are", "we should" all open a list as surely as
"there are three things" does. Two things are a sentence and stay
one.""",
    """Three or more things listed in a row never stay inline. Whatever
joined them — commas, "and", nothing at all — the words introducing
them take a colon and each thing goes on a line of its own behind a
dash. No number has to be said for this: "here is what I need from
you", "the steps are", "we should" all open a list as surely as
"there are three things" does. Two things are a sentence and stay
one.

A speaker counting is a list however it is punctuated. When the
items are numbered out loud — one, two, three; first, second,
third; premièrement, deuxièmement — each numbered item is a line of
its own behind a dash, even when they were said as separate
sentences, and even when there are only two. The count is what is
dropped, never the item it counted: every thing said still appears,
once, in the order it was said. What introduces them keeps its
colon. This is a speaker going through a list out loud, not the
words themselves: "first thing in the morning" and "the one I
meant" are counting nothing and open nothing.""",
)


# v10 — v9's idea, put inside the existing list paragraph instead of after it.
#
# v9 added a paragraph of its own and cost 3 points: it fixed the ordinals said
# as separate sentences and broke two cases the shipped prompt gets right —
# "run the migration, check the error budget and tell support" stopped becoming
# a list at all. A second block about lists competed with the first rather than
# extending it, which is the failure the prompt's own history calls "the rule
# has to sit with the paragraph rule".
#
# So this changes the sentences that are already there: what joins the items
# gains a full stop, counting out loud is named as a second way to open a list,
# and the negative that keeps "first thing in the morning" out of it rides on
# the existing "two things are a sentence" clause rather than arriving as new
# prose.
VARIANTS["v10"] = VARIANTS["v7"].replace(
    """Three or more things listed in a row never stay inline. Whatever
joined them — commas, "and", nothing at all — the words introducing
them take a colon and each thing goes on a line of its own behind a
dash. No number has to be said for this: "here is what I need from
you", "the steps are", "we should" all open a list as surely as
"there are three things" does. Two things are a sentence and stay
one.""",
    """Three or more things listed in a row never stay inline, and
neither does a run the speaker counted out loud — one, two, three;
first, second, third — however few of them there are. Whatever
joined them — commas, "and", full stops, nothing at all — the words
introducing them take a colon and each thing goes on a line of its
own behind a dash, the spoken number dropped and the thing it
counted kept, all of them, in the order they were said. No number
has to be said for this: "here is what I need from you", "the steps
are", "we should" all open a list as surely as "there are three
things" does. Two things nobody counted are a sentence and stay
one, and a number that counts nothing — first thing in the morning,
the one I meant — opens nothing.""",
)


# --- the pipeline, ported from PromptRunner --------------------------------


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
    """The same request LocalLLM.complete makes — /api/generate, thinking off."""
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
    with urllib.request.urlopen(request, timeout=180) as response:
        payload = json.load(response)
    return payload["response"]


def shipped_prompt():
    """The `email` transform as config.example.yaml installs it."""
    config = yaml.safe_load(EXAMPLE_CONFIG.read_text())
    for transform in config.get("transforms", []):
        if transform.get("name") == "email":
            return transform["prompt"]
    sys.exit("no `email` transform in config.example.yaml")


# --- scoring ---------------------------------------------------------------


def check(output, case, forbid_always):
    """Every `require` must match and no `forbid` may. Returns the failures."""
    failures = []
    for pattern in case.get("require", []):
        if not re.search(pattern, output, re.MULTILINE):
            failures.append("missing: " + pattern)
    for pattern in list(case.get("forbid", [])) + forbid_always:
        found = re.search(pattern, output, re.MULTILINE)
        if found:
            failures.append("forbidden: {} -> {!r}".format(pattern, found.group(0)))
    return failures


def run_variant(name, prompt, cases, forbid_always, model, verbose):
    results = []
    started = time.time()
    for case in cases:
        text = case["input"].strip()
        output = clean(ask(model, prompt, text, token_budget(text)))
        failures = check(output, case, forbid_always)
        results.append((case, output, failures))
        if verbose or failures:
            mark = "ok  " if not failures else ("KNOWN" if case.get("known_failure") else "FAIL")
            print("{} {} [{}/{}]".format(mark, case["name"], case["half"], case["category"]))
            if verbose:
                print("     in:  " + text.replace("\n", " ")[:100])
                for line in output.split("\n"):
                    print("     out: " + line)
            for failure in failures:
                print("     " + failure)
    elapsed = time.time() - started

    def tally(subset):
        passed = sum(1 for _, _, f in subset if not f)
        return passed, len(subset)

    scored = [r for r in results if not r[0].get("known_failure")]
    known = [r for r in results if r[0].get("known_failure")]
    halves = {}
    for half in ("layout", "restraint"):
        halves[half] = tally([r for r in scored if r[0]["half"] == half])

    print()
    print("=== {} on {} ===".format(name, model))
    for half, (passed, total) in halves.items():
        print("  {:<10} {}/{}".format(half, passed, total))
    passed, total = tally(scored)
    print("  {:<10} {}/{}  ({:.0f}%)   {:.1f}s".format(
        "overall", passed, total, 100 * passed / total if total else 0, elapsed))
    if known:
        kp, kt = tally(known)
        print("  {:<10} {}/{} (documented, not scored)".format("known", kp, kt))
    print()
    return passed, total


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model")
    parser.add_argument("--variant", default="shipped")
    parser.add_argument("--all", action="store_true", help="every variant in order")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--category", help="only cases in this category")
    args = parser.parse_args()

    data = yaml.safe_load(CASES.read_text())
    cases = data["cases"]
    forbid_always = data.get("forbid_always", [])
    if args.category:
        cases = [c for c in cases if c["category"] == args.category]

    names = ["shipped"] + sorted(VARIANTS) if args.all else [args.variant]
    for name in names:
        prompt = shipped_prompt() if name == "shipped" else VARIANTS.get(name)
        if prompt is None:
            sys.exit("unknown variant: {} (have: shipped, {})".format(
                name, ", ".join(sorted(VARIANTS))))
        run_variant(name, prompt, cases, forbid_always, args.model, args.verbose)


if __name__ == "__main__":
    main()


# --- scoreboard ------------------------------------------------------------
#
# gemma4:e4b, 21 scored cases, ~42s a pass:
#
#                       layout   restraint   overall
#   v6 (was shipped)      5/9       7/12      12/21   57%
#   v7 (now shipped)      8/9      10/12      18/21   86%
#   v8                    7/9      10/12      17/21   81%
#
# What the set was written for: a dictated email ending in a question came
# back signed "Thanks,\n[Your Name]". v6's comments record that exact bug as
# caught and fixed in v3, which is the argument for this file existing — the
# "8/10" it claimed was measured against nothing, so the regression had
# nowhere to show up. The placeholder turned out to be on 4 of 21 cases.
#
# v7 is v6 with the signature rule turned around: what the email *ends* on,
# rather than what is not a signature. Same move that fixed the greeting in
# v2, same reason — a prohibition in this prompt gets read as a topic. Every
# bracket went, and three other cases came with it: an invented "Thanks,"
# above a real name, a dropped spoken "thanks", and a question the model had
# been answering rather than laying out.
#
# v8 is the one to not try again. It cut the closing word loose from the name
# so a spoken "thanks" with nobody signing had a rule of its own. That case
# passed and a genuine signature broke — "thanks nathan" came back as "Nathan"
# with no "Thanks," over it. Net −1. The clause a failure seems to ask for is
# often the clause that deletes something the speaker said.
#
# Three failures left, all pre-dating v7 and none of them signatures:
#
#   * "quick update the migration finished" -> "The migration finished". Two
#     spoken words dropped.
#   * "gonna" -> "going to". The slack prompt has a clause protecting slang
#     and contractions; this one does not.
#   * a subject change inside the body is not split into two paragraphs. Note
#     this one used to "pass" against a weaker assertion: two blank lines
#     anywhere, which the greeting plus an invented signature supplied for
#     free. The body has been one paragraph the whole time.
#
# The first two are one shape — the prompt says "every other word survives"
# and the model deletes anyway — and are the obvious next change. Left alone
# here so that v7 is the only variable in the number above.
#
# Two cases carry `known_failure` and are excluded from the score: a short
# reply ending in a goodbye, in English and French, where the goodbye is
# lifted out as a signature and the reply is dropped. Documented in the
# prompt's comments as having resisted three framings.
#
# --- spoken ordinals: measured, and not a prompt problem --------------------
#
# Reported failure: "Hey Peter, three things for you today. One, I still owe
# you the SLT report. Two, I didn't hear yet from Supabase. Three. Can we move
# our one on one to later?" came back as prose with the numbers deleted — no
# list, and three spoken words gone.
#
# First, a correction to this file. The ordinal cases originally passed,
# because they were hand-written as unpunctuated lowercase runs. Real input to
# this stage is capitalised and punctuated — it is last in the pipeline — and
# that punctuation is the whole signal: the same words as one run become a
# list, as sentences stay sentences. The inputs are now verbatim log lines and
# the set reproduces the failure. A set built from tidier text than production
# measures nothing, and this one did until it was fixed.
#
# Then two variants, on the corrected set:
#
#                            layout   restraint   overall
#   v7 (shipped)               8/12      13/14     21/26   81%
#   v9  (new paragraph)        8/12      12/14     20/26   77%
#   v10 (same paragraph)       9/12      12/14     21/26   81%
#
# Neither ships. v9 fixed the reported case and broke two the shipped prompt
# gets right — "run the migration, check the error budget and tell support"
# stopped listing at all — which is the second block competing with the first.
# v10 put the same idea inside the existing paragraph, fixed the reported case
# and the missing-signature case, and still lost the plain three-in-a-row one.
# Three genuinely different prompts inside one point of each other, trading
# which list case they break: that is the model being measured, not the prompt.
#
# The capability check settles it. gemma4:12b, more than twice the size, on the
# ordinals category:
#
#   shipped   3/5      v10   3/5      — identical, case for case
#
# And its near-miss is the exact failure this prompt's comments record from the
# version that forced ordinals: it built the three dashes and dropped what the
# third one counted. A model twice the size failing the same way on both
# prompts means no wording reaches this.
#
# Where it belongs: a spoken enumeration announces itself with a literal marker
# — a sentence opening "One,", "Two,", "Three.", "First," — and by the rule in
# the skill, when the marker is the thing you are looking for there is nothing
# for a model to find. This is the code_identifiers shape (a 30-line script at
# 100%, the same models at 68% and 55%), and it wants a `command:` transform
# running before the email prompt, splitting a counted run into dashed lines so
# the prompt only ever has to lay out a list that is already a list. Not built
# here; the set is ready for it, and `--script` would be the mode to add.
