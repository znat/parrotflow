#!/usr/bin/env python3
"""Spoken names as identifiers. A transcript on stdin, the rewrite on stdout.

    transforms:
      - name: identifiers
        description: spoken names as identifiers
        command: identifiers.py                        # rules only, 0.03s
      # command: identifiers.py --model gemma4:e4b     # + the model, see below        # next to config.yaml

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

--model asks a local model, and only about what the rules declined: a name
given without a marker in front of it — "call it max retries", "rename the
variable to retry count", "a getter for the user profile name". The rules
cannot see those at all, and the model gets 8/8 on them where the rules get
2/8. It answers with the words only; the casing, the convention and the
substitution stay here, which is the whole reason it works — asked to return
the rewritten sentence instead, the same model scored 68% and capitalised
words nobody asked it to touch.

It is off by default, and the trade is measured rather than assumed. Over 70
cases, adding it takes the sentences that should change from 87% to 100% — and
the sentences that must come back untouched from 94% to 81%, because a model
asked only about what a careful rule refused sees mostly near-misses. Turn it
on if you dictate code all day and will notice; leave it off if a sentence
quietly rewritten would slip past you. It also costs about a second, and a
model that is cold takes longer than the two seconds ParrotFlow waits, in which
case your transcript passes through untouched.

It is yours now. The stop lists below are the part that will want editing:
they say where a name ends, and that boundary is a judgement about how you
speak, not a fact.
"""
import json
import re
import sys
import urllib.request

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


# The prompt, iterated and scored as v4 in scripts/validate-identifiers.py. It
# is asked for one thing only — which words are the name — because everything
# else about this job is a function, a lookup or a string replace.
PROMPT = """\
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


def ask(model, text, endpoint="http://localhost:11434"):
    """The name the model found, or None. Every failure is None: Ollama not
    running is an ordinary state, and the transcript is not worth dropping."""
    body = {"model": model, "system": PROMPT, "prompt": text, "stream": False,
            "think": False, "options": {"temperature": 0, "num_predict": 24}}
    request = urllib.request.Request(
        endpoint + "/api/generate", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return (json.load(response).get("response") or "").strip()
    except Exception:
        return None


def place(span, text):
    """`span` cased and put back where it came from — the deterministic half,
    shared with the rules above so there is one algorithm and not two."""
    if not span:
        return text
    span = span.strip().strip('".')
    if re.search(r"\bno name\b|\bnone\b", span, re.I):
        return text
    words = [word for word in re.split(r"[^\w'’]+", span) if word]
    if len(words) < 2 or len(words) > 4:
        return text
    # Only words that are actually in the sentence. A model that answered with
    # its own phrasing has not found anything here.
    if span.lower() not in text.lower():
        return text
    start = text.lower().index(span.lower())
    return (text[:start] + cased(words, style_for(text, text[:start]))
            + text[start + len(span):])


if __name__ == "__main__":
    model = None
    if "--model" in sys.argv:
        index = sys.argv.index("--model")
        model = sys.argv[index + 1] if len(sys.argv) > index + 1 else None

    text = sys.stdin.read().rstrip("\n")
    out = convert(text)
    # The model is asked only about what the rules declined. On a sentence with
    # a marker in it — the common case — nothing is paid at all.
    if model and out == text:
        out = place(ask(model, text), text)
    sys.stdout.write(out)
