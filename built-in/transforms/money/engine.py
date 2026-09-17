"""Writing a dictated amount of money, minus the language. Imported by the
language files beside it.

An amount has two halves: a number and a currency word. This transform runs
AFTER `numbers_<code>`, which has written "three thousand dollars" as
"3000 dollars", and rewrites what is left: the currency word becomes its
symbol, in the place the language puts it.

`numbers` leaves a lone number under ten as a word on purpose — "chapter
three" — so "five dollars" arrives in words. Each language file reads those
ten words itself. That keeps `numbers` free of any knowledge of this stage.

That is the one way this differs from `dates`, which runs BEFORE numbers and
reads all the words itself. Money needs every magnitude, and
`numbers/engine.py` is where that lives and where it is scored.

A language file exposes `RULES`, an ordered list of (name, compiled regex,
handler). A handler is `f(match, text) -> str | None`: what to write in place
of the match, or None to leave it alone. Order is the whole of rule precedence.

Both languages spell `dollars` and `euros` the same way, which no pair of
`dates` files does. Without a guard `money_en` would write "20 dollars" said
in French as "$20". `ctx.language` decides: a script declines everything when
the pipeline detected another language.

Unlike `numbers/engine.py`, there is no word count. The count would be taken on
text `numbers` already shortened — "vingt et un euros chacun" reaches this
stage as "21 euros chacun", three words — so the guard turned off on a French
sentence and `money_en` wrote "€21". A short transcript is still handled: the
app gives it the first configured language, and that script writes it.

Adding a language: copy `fr.py`, edit its words, symbols and RULES, write
`cases-<code>.yaml` beside it, and add a `transforms:` entry and a step below
the numbers step.
"""
import json
import os
import re
import sys

def alt(words):
    """An alternation, longest first — "dollars" must beat "dollar"."""
    return "|".join(re.escape(w) for w in sorted(words, key=lambda w: (-len(w), w)))


def word_after(text, at):
    """The next word after offset `at`, lowercased, or "" at the end."""
    found = re.match(r"\s*([\w'’-]+)", text[at:])
    return found.group(1).lower() if found else ""


def value(raw, units):
    """The amount as digits: a digit run as it is, or a unit word's value."""
    if raw[0].isdigit():
        return raw
    return str(units[raw.lower()])


def half_of_a_number(m, text, tens):
    """Whether a unit word is the end of a bigger number nothing converted.

    "ninety nine euros" and "quatre-vingt-dix neuf euros" end in a unit word,
    and reading only that word writes "ninety €9". `numbers` above this stage
    normally writes them first, so this only matters when it did not run. The
    word before is read hyphen by hyphen, so "quatre-vingt-dix" ends in "dix".
    Digits are never checked: "10 euros et 20 euros" has a number word, "et",
    in front of its second amount, and that amount is still one.
    """
    if m.group("n")[0].isdigit():
        return False
    before = re.split(r"[\s\-\u2011]+", text[:m.start("n")].strip().lower())
    return bool(before) and before[-1] in tens


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


def declines(code, language, _text):
    """Whether another language's script should keep its hands off this text.

    `dollars` and `euros` are the same word in both languages, so the guard
    `dates` never needed is mandatory here. No language — a bare
    `echo … | en.py` — declines nothing.
    """
    return bool(language) and language != code


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
