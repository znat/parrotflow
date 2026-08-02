#!/usr/bin/env python3
"""Spoken names as identifiers. A transcript on stdin, the rewrite on stdout.

    transforms:
      - name: identifiers
        description: spoken names as identifiers
        command: identifiers.py        # next to config.yaml

    transcription:
      pipelines:
        default: [replacements, fuzzy, numbers]
        # add it yourself:
        #   - transform: identifiers

"a python function called max retries"  ->  "a python function called max_retries"

The convention comes from the language if one was said, and is camelCase when
none was. A class or a type takes PascalCase whatever the language; a constant
takes SCREAMING_SNAKE_CASE.

This is not in the default pipeline and is not installed anywhere. Copy it to
~/.config/parrotflow/, make it executable, and add the two lines above.

Why a script and not a prompt: measured. On tests/identifier-cases.yaml, 56
cases, this scores 100% and costs a process start; gemma4:e4b scores 68% and
costs a second — and its errors are the expensive kind, capitalising words it
was not asked to touch and translating French names into English. See
scripts/validate-identifiers.py for the scoreboard.

It is yours now. The stop lists below are the part that will want editing:
they say where a name ends, and that boundary is a judgement about how you
speak, not a fact.
"""
import re
import sys

# A name has to be introduced as one. Without this, "i called max yesterday"
# is a naming and the transform renames a person.
KIND = re.compile(
    r"\b(?:function|method|variable|class|constant|type|struct|interface|enum|"
    r"fonction|m[ée]thode|variable|classe|constante)\b", re.I)

# "called by the scheduler" is a passive and never a naming.
TRIGGER = re.compile(
    r"\b(?:called|named|call it|nomm[ée]e?|qui s['’]appelle|appel[ée]e?)\s+"
    r"(?!by\b|par\b)", re.I)

# Where the name stops and the sentence resumes. "in", "from", "on" and "to"
# were here and had to come out — they are ordinary parts of identifiers
# ("is logged in", "build request from config") and stopping there truncated
# the name.
TAIL = re.compile(
    r"\b(?:that|which|for|and|so|should|will|when|if|because|"
    r"qui|que|pour|et|dans|sur|avant|apr[èe]s|doit)\b", re.I)

SNAKE_LANGUAGES = re.compile(r"\b(?:python|rust|ruby|elixir)\b", re.I)
PASCAL_KIND = re.compile(r"\b(?:class|classe|type|struct|interface|enum)\b", re.I)
SCREAMING_KIND = re.compile(r"\b(?:constant|constante)\b", re.I)


def style_for(sentence, before):
    if SCREAMING_KIND.search(before):
        return "screaming"
    if PASCAL_KIND.search(before):
        return "pascal"
    if SNAKE_LANGUAGES.search(sentence):
        return "snake"
    return "camel"


def cased(words, style):
    if style == "snake":
        return "_".join(word.lower() for word in words)
    if style == "screaming":
        return "_".join(word.upper() for word in words)
    if style == "pascal":
        return "".join(word.capitalize() for word in words)
    return words[0].lower() + "".join(word.capitalize() for word in words[1:])


def convert(text):
    out = text
    # Right to left, so an earlier rewrite cannot move a later match.
    for match in list(TRIGGER.finditer(text))[::-1]:
        if not KIND.search(text[:match.start()]):
            continue
        rest = text[match.end():]
        stop = TAIL.search(rest)
        span = (rest[:stop.start()] if stop else rest).strip()
        words = [word for word in re.split(r"[^\w'’]+", span) if word]
        # One word is already an identifier, whatever its case.
        if len(words) < 2:
            continue
        # Nobody dictates a five-word identifier, and prose runs on: "the class
        # called intro to python starts at nine tomorrow" is not a naming, and
        # the length is what says so. Declining rather than truncating — a
        # shortened guess is a wrong rewrite, and this is a stage that runs on
        # sentences nobody asked it to touch.
        if len(words) > 4:
            continue
        if span in out:
            out = out.replace(span, cased(words, style_for(text, text[:match.start()])), 1)
    return out


if __name__ == "__main__":
    sys.stdout.write(convert(sys.stdin.read().rstrip("\n")))
