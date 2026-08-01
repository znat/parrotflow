#!/usr/bin/env python3
"""Can the router answer a third way: ANY — an edit, but no tool fits?

    scripts/validate-gate.py gemma4:e4b

This measured the proposal before it existed. The third answer shipped, so the
live scoreboard is now tests/routing-cases.yaml through scripts/check-routing.sh
— that one reads your real catalogue and runs the real prompt, and is what to
reach for first. Kept because it needs neither a build nor a config, which is
what makes it the quick way to ask whether a *different* model can hold the
three-way distinction at all.

Two things it is not. The listing below is a hand copy of a catalogue, in a
different order and a different separator from `Catalogue.listing`, and the
decoys are fixed rather than generated from the entries. So it scores the shape
of the idea, not the string Router.swift builds.

The problem it exists to settle. A generic transform hung off the router's
NONE inherits every idle sentence, because NONE today means both "not an
edit" and "an edit I have no tool for" — so "what is the weather tomorrow",
said with text selected, would arrive at a prompt whose whole job is to
change the text. The catalogue-entry version of the same idea was tried first
and does not work: an `anything — any other change to the text` entry was
picked zero times out of ten, an abstract description losing every time to
concrete ones.

The listing below is a copy of a catalogue, not a read of one, so this runs
without a config and without a build. Keep it in step with the real prompt in
Router.swift if that ever gains the third answer.

Scores are in the notes at the bottom of scripts/validate-generic.py.
"""
import json, sys, urllib.request

MODEL = sys.argv[1] if len(sys.argv) > 1 else "gemma4:e4b"

LISTING = """\
bullets — turn text into a short bullet list
terse — shorten text without losing anything it says
grammar — fix grammar and punctuation, changing nothing else
spelling — fix a misheard word using a spelling the speaker reads out
vocabulary — open the panel to teach a spelling by hand"""

PROMPT = f"""\
Choose which tool handles the instruction.

Tools:
{LISTING}

Reply with exactly one tool name from the list above, or ANY, or NONE. \
Nothing else — no punctuation, no explanation.

- Every tool changes text the speaker has already written. Route only when \
the instruction asks for that.
- Reply ANY when the instruction does ask for a change to the text, but no \
tool in the list makes that change.
- Reply NONE when the instruction is not asking for a change to the text at \
all. A question, or a remark about something else, is NONE however many words \
it shares with a tool.
- The instruction often carries extra detail ("but not the years", "as ISO"). \
That detail is for the tool, not for you. Route on the request.

instruction: turn text into a short bullet list
bullets

instruction: did you see the bullets I sent yesterday
NONE

instruction: we talked about bullets in the meeting
NONE

instruction: Tasmin spells T A S M E E N
spelling

instruction: what is the weather tomorrow
NONE

instruction: put every heading in capitals
ANY
"""

CASES = [
    # not an instruction at all
    ("what does this even mean", "NONE"),
    ("I bought a box of bullets yesterday", "NONE"),
    ("what is the weather tomorrow", "NONE"),
    ("we talked about the dates in the meeting", "NONE"),
    ("how long is that going to take", "NONE"),
    ("the terse version was better", "NONE"),
    # a real edit, no narrow tool for it
    ("format the amounts as dollars", "ANY"),
    ("convert that to metric", "ANY"),
    ("use the 24 hour clock", "ANY"),
    ("make it title case", "ANY"),
    ("sort the list alphabetically", "ANY"),
    ("remove the parentheses", "ANY"),
    ("convert the date to ISO", "ANY"),
    ("write the numbers as digits", "ANY"),
    ("swap the two names round", "ANY"),
    # the narrow tools must still win
    ("fix the grammar and punctuation", "grammar"),
    ("make that a bullet list", "bullets"),
    ("cut this down a bit", "terse"),
    ("Tasmin is spelled T A S M E E N", "spelling"),
]


def ask(instruction):
    body = {
        "model": MODEL, "system": PROMPT, "prompt": f"instruction: {instruction}",
        "stream": False, "think": False,
        "options": {"temperature": 0, "num_predict": 8}, "keep_alive": "24h",
    }
    request = urllib.request.Request(
        "http://localhost:11434/api/generate",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)["response"].strip().strip(".").split("\n")[0]


hit = 0
loose = 0   # ANY answered as NONE is a miss; NONE answered as ANY is a rewrite
for instruction, want in CASES:
    got = ask(instruction)
    ok = got.lower() == want.lower()
    hit += ok
    if not ok and want == "NONE":
        loose += 1
    print(f"  {'✓' if ok else '✗'} {instruction:<44} got {got:<9} want {want}")
print(f"\n  {MODEL}: {hit}/{len(CASES)}"
      + (f"   {loose} idle sentence(s) sent to a tool  ← the one that costs text" if loose else ""))
