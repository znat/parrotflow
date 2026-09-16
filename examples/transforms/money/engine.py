"""Writing a dictated amount of money, minus the language. Imported by the
language files beside it.

An amount has two halves: a number and a currency word. This transform reads
no number words at all. It runs AFTER `numbers_<code>`, which has written
"three thousand dollars" as "3000 dollars" — and, because a currency word is
in its `currency` set, "five dollars" as "5 dollars" too. So the amount is
always digits by the time it gets here, and the pattern is `\d+`.

That is the one way this differs from `dates`, which runs BEFORE numbers and
reads the words itself. Money needs every magnitude, and `numbers/engine.py`
is where that lives and where it is scored. Reading words here as well cost
two bugs before it was dropped: "ninety-nine Euros" became "ninety-€9", and
"10 euros et 20 euros" lost its second amount.

The coupling is real and deliberate: take `numbers_<code>` out of the pipeline
and this stage sees no digits to work with.

A language file exposes `RULES`, an ordered list of (name, compiled regex,
handler). A handler is `f(match, text) -> str | None`: what to write in place
of the match, or None to leave it alone. Order is the whole of rule precedence.

Both languages spell `dollars` and `euros` the same way, which no pair of
`dates` files does. Without a guard `money_en` would write "20 dollars" said
in French as "$20". `ctx.language` decides: a script declines everything when
the pipeline detected another language and the transcript is long enough for
that detection to mean something. Below `MINIMUM_WORDS` the guard is off and
the first step in the pipeline wins, exactly as in `numbers/engine.py`.

Adding a language: copy `fr.py`, edit its words, symbols and RULES, write
`cases-<code>.yaml` beside it, and add a `transforms:` entry and a step below
the numbers step.
"""
import json
import os
import re
import sys

# `DictationLanguage.minimumWords`: below four words the recogniser's answer is
# a coin toss, so no language file is held to the cross-language guard.
MINIMUM_WORDS = 4


def alt(words):
    """An alternation, longest first — "dollars" must beat "dollar"."""
    return "|".join(re.escape(w) for w in sorted(words, key=lambda w: (-len(w), w)))


def word_after(text, at):
    """The next word after offset `at`, lowercased, or "" at the end."""
    found = re.match(r"\s*([\w'’-]+)", text[at:])
    return found.group(1).lower() if found else ""


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
    """The amounts in `text`, written with their symbol."""
    applied = [] if applied is None else applied
    for name, pattern, handler in rules:
        text = apply_rule(text, name, pattern, handler, applied)
    return text


def declines(code, language, text):
    """Whether another language's script should keep its hands off this text.

    `dollars` and `euros` are the same word in both languages, so the guard
    `dates` never needed is mandatory here.
    """
    return ((language or code) != code
            and len(text.split()) >= MINIMUM_WORDS)


def main(module):
    """The entry point every language file ends with."""
    # ParrotFlow sets PARROTFLOW_PROTOCOL=json when the transform declares
    # `returns: json`, and then stdin is the envelope. Unset is the plain path,
    # which is what a bare `echo … | en.py` gets.
    structured = os.environ.get("PARROTFLOW_PROTOCOL") == "json"
    raw = sys.stdin.read()
    envelope = json.loads(raw) if structured else {"text": raw}
    text = envelope["text"]
    language = (envelope.get("ctx") or {}).get("language") or ""

    applied = []
    try:
        if declines(module.CODE, language, text):
            out = text
        else:
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
        # Deduplicated: two amounts in one sentence name the rule once.
        "vars": {"count": len(applied),
                 "applied": ", ".join(dict.fromkeys(applied)),
                 "language": language},
    }))
