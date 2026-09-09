"""The part of writing a dictated date that is not about any language.

Not a transform and not runnable. `en.py` and `fr.py` are the transforms; this
holds the loop they share, the JSON protocol, and the `--when` printer.

**A dictated date already carries its format.** "le dix du douze" is `10/12`
because the speaker chose day-then-month; "March third twenty twenty-six" is
`March 3, 2026` because they chose month-then-day. No language file is told a
target format and none of them reads a calendar: no "next Tuesday", no year
invented for a date that was said without one. The shape is in the utterance.
The same idea, and why `DateRewriter.swift` was parked for it, is in that
file's header.

## What a language file must expose

    RULES        an ordered list of (name, compiled regex, handler)
    gate_parts() a list of regex fragments for the `when:` line

A handler is `f(match, text) -> str | None`. It returns what to write in place
of the match, or None to leave it alone. Order is the whole of rule
precedence: dates before times, and the longest form of a time before its
shorter ones. `rewrite` applies each rule left to right over the text, taking
non-overlapping matches, and a rule never sees another rule's output.

`ctx.language` is read and published as `<stage>.language`. It is never acted
on. Each language is its own pipeline step, so the config already chose; and a
French clock phrase inside an English transcript is still a French clock
phrase. The cue words barely overlap — "heures" is not an English word and
"o'clock" is not a French one — so the wrong script on a transcript writes
nothing, and declining on the language would only cost the mixed sentences.

## Adding a language

Copy `fr.py` to `es.py` and work through it. Nothing here changes.

1. Edit the word tables at the top: units, teens, tens, the ordinal a date
   uses, the month names, the cue words.
2. Edit the readers under them, then the handlers, then `RULES`.
3. Edit `gate_parts()` so every case that must change matches it.
4. Add a `transforms:` entry to `config.yaml`:

       - name: dates_es
         description: dictated dates and clock times as digits
         command: examples/dates/es.py
         returns: json
         tests: examples/dates/es-cases.yaml

5. Add a pipeline step above the numbers steps, with the gate the script
   prints:

       - transform: dates_es
         when: <the regex printed by `es.py --when`>

6. Write `es-cases.yaml` beside the script. A third of it should be text that
   looks like a date and is not.
7. Score it:

       examples/transforms/dates/score.py            # every language
       examples/transforms/dates/score.py --lang es
       ParrotFlow --eval dates_es                    # `tests:` finds the file

The word tables are copied between language files on purpose. They are about
forty words each and they do not move; one shared table would make every
language file a place the others can break.
"""
import json
import os
import re
import sys


def alt(words):
    """An alternation, longest first — "quatorze" must beat "quatre".

    Alphabetical within a length, so a set of words always prints the same
    regex. Without the tie-break `--when` printed a different line every run
    and the one in config.yaml could never be checked against it.
    """
    return "|".join(re.escape(w) for w in sorted(words, key=lambda w: (-len(w), w)))


def apply_rule(text, name, pattern, handler, applied):
    """Every non-overlapping match the handler accepts, left to right."""
    out, at = [], 0
    for m in pattern.finditer(text):
        if m.start() < at:
            continue
        written = handler(m, text)
        if written is None or written == m.group(0):
            continue
        out.append(text[at:m.start()])
        out.append(written)
        at = m.end()
        applied.append(name)
    out.append(text[at:])
    return "".join(out)


def rewrite(text, rules, applied=None):
    """The dates and times in `text`, written as they were spoken."""
    applied = [] if applied is None else applied
    for name, pattern, handler in rules:
        text = apply_rule(text, name, pattern, handler, applied)
    return text


def when(module):
    """The `when:` regex for the pipeline step, from the language's own cues.

    A gate, not the grammar: it lets through everything the rules could fire
    on, and nothing else pays for a python3 start. Generated rather than typed
    — a gate that misses a word is a silent miss, and nothing would show it
    happening. `score.py` fails if a case that must change does not match it.

    Slashes included. A `when:` between them is a regular expression and
    anything else is an expression over the scope, so the printed line is
    pasted as it stands. `(?i)` is stated rather than assumed: the pipeline
    compiles a `when:` case-insensitively already, but the regex is also read
    by `score.py` and by whoever pastes it somewhere else.
    """
    return "/(?i)" + "|".join(module.gate_parts()) + "/"


def main(module):
    """The entry point every language file ends with."""
    if "--when" in sys.argv[1:]:
        print(when(module))
        return

    # ParrotFlow sets PARROTFLOW_PROTOCOL=json when the transform declares
    # `returns: json`, and then stdin is the envelope. Unset is the plain path,
    # which is what a bare `echo … | en.py` gets.
    structured = os.environ.get("PARROTFLOW_PROTOCOL") == "json"
    raw = sys.stdin.read()
    envelope = json.loads(raw) if structured else {"text": raw}
    text = envelope["text"]

    applied = []
    try:
        out = rewrite(text, module.RULES, applied)
    except Exception:
        # Fail open — never drop the whole transcript because a guard threw.
        out = text
        applied.clear()

    if not structured:
        sys.stdout.write(out)
        return
    print(json.dumps({
        "text": out,
        # Deduplicated: two times in one sentence name the rule once.
        "vars": {"count": len(applied),
                 "applied": ", ".join(dict.fromkeys(applied)),
                 "language": (envelope.get("ctx") or {}).get("language") or ""},
    }))
