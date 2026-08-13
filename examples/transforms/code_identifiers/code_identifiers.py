#!/usr/bin/env python3
"""Spoken names as identifiers. A transcript on stdin, the rewrite on stdout.

    transforms:
      - name: code_identifiers
        description: spoken names as identifiers
        display: Formatting identifiers
        command: code_identifiers.py                       # rules only, 0.03s
      # command: code_identifiers.py --model gemma4:e4b     # + the model, below
        timeout_seconds: 12                                 # only with --model

    transcription:
      pipelines:
        default:
          - transform: code_identifiers
            when: /\b(?:function|variable|class|constant|fonction|classe)\b/

"a python function called max retries"  ->  "a python function called max_retries"

The convention comes from the language if one was said, and is camelCase when
none was. A class or a type takes PascalCase whatever the language; a constant
takes SCREAMING_SNAKE_CASE.

A copy of this folder — this file and cases.yaml beside it — is written to
~/.config/parrotflow/transforms/code_identifiers/ on first launch and never
overwritten afterwards, and the step above is in the default pipeline. This
one, in examples/, is the copy you read and edit; see
scripts/check-seeded-transform.sh, which keeps the two equal.

Why a script and not a prompt: measured. On examples/transforms/code_identifiers/cases.yaml, 56
cases, this scores 100% and costs a process start; gemma4:e4b scores 68% and
costs a second — and its errors are the expensive kind, capitalising words it
was not asked to touch and translating French names into English. See
scripts/validate-code-identifiers.py for the scoreboard.

--model asks a local model, and only about what the rules declined: a name
given without a marker in front of it — "call it max retries", "rename the
variable to retry count", "a getter for the user profile name". The rules
cannot see those at all, and the model gets 8/8 on them where the rules get
2/8.

It extracts rather than rewrites — the language, and the names — and everything
after that stays here. That division is the whole reason it works: asked to
return the rewritten sentence instead, the same model scored 68% and
capitalised words nobody asked it to touch.

It is off by default, and the trade is measured rather than assumed. Over 75
cases, adding it takes the sentences that should change from 87% to 100% — and
the sentences that must come back untouched from 94% to 84%, because a model
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
import os
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

# The convention each language writes identifiers in. A table rather than a
# pattern, because a pattern has to be edited to learn a language and a table
# has to be added to — and everything it does not know reads as camelCase,
# which was silently wrong for zig, julia, erlang and c# until this was a
# table. Add your own; it is a dict, not a regex.
BY_LANGUAGE = {
    "python": "snake", "py": "snake", "rust": "snake",
    "ruby": "snake", "rb": "snake", "elixir": "snake",
    "erlang": "snake", "julia": "snake", "perl": "snake", "zig": "snake",
    "nim": "snake", "crystal": "snake", "lua": "snake", "c": "snake",
    "javascript": "camel", "typescript": "camel", "java": "camel",
    "kotlin": "camel", "go": "camel", "swift": "camel", "php": "camel",
    "scala": "camel", "dart": "camel", "groovy": "camel", "haskell": "camel",
    "c#": "pascal", "csharp": "pascal", "f#": "pascal",
}
# "c#" ends in a character no word boundary follows, so the trailing \b would
# never match it — the boundary has to be asserted on the left only, plus "not
# followed by more word characters".
LANGUAGE = re.compile(
    r"\b(" + "|".join(re.escape(name) for name in sorted(BY_LANGUAGE, key=len, reverse=True))
    + r")(?!\w)", re.I)
PASCAL_KIND = re.compile(r"\b(?:class|classe|type|struct|interface|enum)\b", re.I)
SCREAMING_KIND = re.compile(r"\b(?:constant|constante)\b", re.I)


def style_for(sentence, before, language=None):
    """A kind word in front of the name wins — a class is PascalCase in any
    language — then the language, then camelCase for a sentence that named
    none."""
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
    """The rewrite. `converted`, if given, is appended one entry per name taken.

    An out-parameter rather than a second return value because
    `scripts/validate-code-identifiers.py` calls this as `shipped.convert` and
    compares its result to a string — a tuple would have changed what the
    scoreboard measures in order to add a number nothing there reads.
    """
    out = text
    # Right to left, so an earlier rewrite cannot move a later match.
    for match in list(TRIGGER.finditer(text))[::-1]:
        if not KIND.search(text[:match.start()]):
            continue
        rest = text[match.end():]
        stop = TAIL.search(rest)
        window = rest[:stop.start()] if stop else rest
        span = window.strip()
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
        # Position, not text search — the same words can sit earlier as
        # ordinary prose, and a search would rewrite that copy instead.
        start = match.end() + (len(window) - len(window.lstrip()))
        end = start + len(span)
        out = out[:start] + cased(words, style_for(text, text[:match.start()])) + out[end:]
        if converted is not None:
            converted.append(span)
    return out


# The prompt, iterated and scored as v5 in scripts/validate-code-identifiers.py.
#
# It extracts rather than rewrites: the language once, the names one per line.
# Everything after that is code — the language becomes a convention through
# BY_LANGUAGE above, a kind word still overrides it for a class or a constant,
# and putting the words back is a string replace.
#
# Asking for the language rather than pattern-matching it is what makes the
# table extensible without touching the prompt, and it is why the model is
# still worth asking once the table exists: a sentence can name a language in a
# way no scan of it will catch.
PROMPT = """\
The text is a dictated sentence. Some of them give names to functions, \
variables, classes or constants.

Reply in exactly this shape and nothing else:

lang: <the programming language the sentence names, or none>
name: <the words of one name, copied exactly>

Repeat the name line once per name. Write no name line at all when the \
sentence names nothing.

- Copy the words exactly as they appear. Do not rewrite them, join them or \
change their case — that is done elsewhere.
- A name is two to four words. Take the whole name and only the name.
- The name may be given without the word "called": "call it X", "rename it to \
X", "a getter for X".
- Write no name line when the sentence merely talks about a function, a class \
or a variable, or is about something else entirely.

text: add a rust function called read config file
lang: rust
name: read config file

text: call it max retries in python
lang: python
name: max retries

text: a python function called read config and a variable called config path
lang: python
name: read config
name: config path

text: the retry count is too high and it hammers the api
lang: none

text: we talked about python packaging for most of the afternoon
lang: python

text: there is a method called cognitive behavioural therapy for that
lang: none
"""


def ask(model, text, endpoint="http://localhost:11434"):
    """The model's answer, or "" for every way this can fail. Ollama not
    running is an ordinary state and a transcript is not worth dropping."""
    body = {"model": model, "system": PROMPT, "prompt": text, "stream": False,
            "think": False, "options": {"temperature": 0, "num_predict": 64}}
    request = urllib.request.Request(
        endpoint + "/api/generate", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return (json.load(response).get("response") or "").strip()
    except Exception:
        return ""


def place(reply, text, converted=None):
    """The extraction applied — the deterministic half, sharing `cased` and
    `style_for` with the rules above so there is one algorithm and not two.

    `converted` is appended one entry per name taken, exactly as `convert` does
    — the two paths produce the same kind of rewrite and have to report it the
    same way. A model conversion that did not count would publish `count: 0` on
    a sentence this stage had just rewritten, and the stage below, told to stand
    down when the count is zero, would run anyway.
    """
    language, names = None, []
    for line in reply.splitlines():
        line = line.strip()
        if line.lower().startswith("lang:"):
            said = line.split(":", 1)[1].strip().lower()
            language = None if said in ("none", "") else said
        elif line.lower().startswith("name:"):
            names.append(line.split(":", 1)[1].strip())

    out = text
    for span in names:
        span = span.strip().strip('".')
        words = [word for word in re.split(r"[^\w'’]+", span) if word]
        # The same guards the rules use: a name is two to four words, and the
        # model does not get to invent words that are not in the sentence.
        if len(words) < 2 or len(words) > 4 or span.lower() not in out.lower():
            continue
        # The last occurrence, not the first: the model extracts names from
        # "call it X" / "rename it to X", and both put X after whatever prose
        # introduced it — "the user profile name is shown in settings; call it
        # user profile name" repeats the words once as prose and once as the
        # declaration, in that order.
        start = out.lower().rfind(span.lower())
        out = (out[:start] + cased(words, style_for(out, out[:start], language))
               + out[start + len(span):])
        if converted is not None:
            converted.append(span)
    return out


if __name__ == "__main__":
    model = None
    if "--model" in sys.argv:
        index = sys.argv.index("--model")
        model = sys.argv[index + 1] if len(sys.argv) > index + 1 else None

    # Two protocols, and which one is in force is decided by the config rather
    # than by anything here: ParrotFlow sets PARROTFLOW_PROTOCOL=json when the
    # transform declares `returns: json`, and leaves it unset otherwise.
    #
    # Reading the environment rather than taking a flag keeps `returns:` the
    # single declaration — a flag in the `command:` line would say the same
    # thing one line lower and could disagree with it. It also keeps this
    # runnable by hand: `echo "a python function called max retries" |
    # ./code_identifiers.py` takes the plain path, which is what every harness
    # in scripts/ does and what anybody debugging one will type.
    structured = os.environ.get("PARROTFLOW_PROTOCOL") == "json"

    raw = sys.stdin.read()
    if structured:
        text = json.loads(raw)["text"]
    else:
        text = raw.rstrip("\n")

    converted = []
    out = convert(text, converted)
    asked = False
    # The model is asked only about what the rules declined. On a sentence with
    # a marker in it — the common case — nothing is paid at all.
    #
    # `converted` is passed on rather than reset: the branch is only reached
    # when the rules took nothing, so it is empty here — but threading it keeps
    # `count` meaning "names this stage converted" regardless of which half did
    # it, which is the only reading a condition below can rely on.
    if model and out == text:
        asked = True
        out = place(ask(model, text), text, converted)

    if not structured:
        sys.stdout.write(out)
        raise SystemExit(0)

    # `count` is what a later stage wants: `dotted` should stand down when this
    # already took the sentence, and until now the only way to ask was to
    # re-derive the judgement from the words. `asked` is for the log rather than
    # for a condition — it is the difference between a stage that cost nothing
    # and one that cost a second, and it was previously invisible.
    sys.stdout.write(json.dumps({
        "text": out,
        "vars": {"count": len(converted), "asked_model": asked},
    }))
