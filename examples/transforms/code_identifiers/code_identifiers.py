#!/usr/bin/env python3
"""Spoken names as identifiers. Transcript on stdin, rewrite on stdout.

    transforms:
      - name: code_identifiers
        description: spoken names as identifiers
        display: Formatting identifiers
        command: code_identifiers.py

"a python function called max retries"  ->  "a python function called max_retries"

Convention: the spoken language if one was said, camelCase otherwise. A class
or type is always PascalCase; a constant is always SCREAMING_SNAKE_CASE.

This folder is copied to ~/.config/parrotflow/transforms/code_identifiers/ on
first launch and never overwritten after — this is the one to edit.

Rules only, no model: scripts/validate-code-identifiers.py --code-only scores
this at 91% on cases.yaml.
"""
import json
import os
import re
import sys

# A name has to be introduced as one, or "i called max yesterday" renames a person.
KIND = re.compile(
    r"\b(?:function|method|variable|class|constant|type|struct|interface|enum|"
    r"fonction|m[ée]thode|variable|classe|constante)\b", re.I)

# "called by the scheduler" is passive, never a naming.
TRIGGER = re.compile(
    r"\b(?:called|named|call it|nomm[ée]e?|qui s['’]appelle|appel[ée]e?)\s+"
    r"(?!by\b|par\b)", re.I)

# Where the name stops. `in/from/on/to` are excluded: they are ordinary parts
# of identifiers ("is logged in", "build request from config").
TAIL = re.compile(
    r"\b(?:that|which|for|and|so|should|will|when|if|because|"
    r"qui|que|pour|et|dans|sur|avant|apr[èe]s|doit)\b", re.I)

# The casing convention per language. Unknown languages read as camelCase.
BY_LANGUAGE = {
    "python": "snake", "py": "snake", "rust": "snake", "ruby": "snake",
    "rb": "snake", "elixir": "snake", "erlang": "snake", "julia": "snake",
    "perl": "snake", "zig": "snake", "nim": "snake", "crystal": "snake",
    "lua": "snake", "c": "snake",
    "javascript": "camel", "js": "camel", "typescript": "camel", "ts": "camel",
    "java": "camel", "kotlin": "camel", "go": "camel", "golang": "camel",
    "swift": "camel", "php": "camel", "scala": "camel", "dart": "camel",
    "groovy": "camel", "haskell": "camel",
    "c#": "pascal", "csharp": "pascal", "f#": "pascal",
}
# "c#" has no trailing \b, so the boundary is asserted on the left only.
LANGUAGE = re.compile(
    r"\b(" + "|".join(re.escape(name) for name in sorted(BY_LANGUAGE, key=len, reverse=True))
    + r")(?!\w)", re.I)
PASCAL_KIND = re.compile(r"\b(?:class|classe|type|struct|interface|enum)\b", re.I)
SCREAMING_KIND = re.compile(r"\b(?:constant|constante)\b", re.I)

# Already punctuated — `dotted` runs first and can hand this "called
# user.name". Without this guard it would re-case what `dotted` just built.
PUNCTUATED = re.compile(r"[.\-_]")


def style_for(sentence, before, language=None):
    """A kind word in front wins — a class is PascalCase in any language —
    then the language, then camelCase for a sentence that named none."""
    if SCREAMING_KIND.search(before):
        return "screaming"
    if PASCAL_KIND.search(before):
        return "pascal"
    if not language:
        found = LANGUAGE.search(sentence)
        language = found.group(1) if found else None
    return BY_LANGUAGE.get((language or "").lower(), "camel")


def cased(words, style):
    if style == "snake":
        return "_".join(word.lower() for word in words)
    if style == "screaming":
        return "_".join(word.upper() for word in words)
    if style == "pascal":
        return "".join(word.capitalize() for word in words)
    return words[0].lower() + "".join(word.capitalize() for word in words[1:])


def convert(text, converted=None):
    """The rewrite. `converted`, if given, gets one entry per name taken."""
    out = text
    # Right to left, so an earlier rewrite cannot move a later match.
    for match in list(TRIGGER.finditer(text))[::-1]:
        if not KIND.search(text[:match.start()]):
            continue
        rest = text[match.end():]
        stop = TAIL.search(rest)
        window = rest[:stop.start()] if stop else rest
        span = window.strip()
        # Already punctuated by `dotted` or the speaker — don't re-case it.
        if PUNCTUATED.search(span):
            continue
        words = [word for word in re.split(r"[^\w'’]+", span) if word]
        if len(words) < 2:      # one word is already an identifier
            continue
        if len(words) > 4:      # nobody dictates a five-word identifier
            continue
        # Position, not text search — the same words can sit earlier as
        # ordinary prose, and a search would rewrite that copy instead.
        start = match.end() + (len(window) - len(window.lstrip()))
        end = start + len(span)
        out = out[:start] + cased(words, style_for(text, text[:match.start()])) + out[end:]
        if converted is not None:
            converted.append(span)
    return out


if __name__ == "__main__":
    # ParrotFlow sets PARROTFLOW_PROTOCOL=json when the transform declares
    # `returns: json`; unset otherwise, which keeps this runnable by hand.
    structured = os.environ.get("PARROTFLOW_PROTOCOL") == "json"

    raw = sys.stdin.read()
    text = json.loads(raw)["text"] if structured else raw.rstrip("\n")

    converted = []
    out = convert(text, converted)

    if not structured:
        sys.stdout.write(out)
        raise SystemExit(0)

    # `count` lets a later stage stand down — e.g. `dotted` when this already
    # took the sentence — without re-deriving the judgement from the words.
    sys.stdout.write(json.dumps({"text": out, "vars": {"count": len(converted)}}))
