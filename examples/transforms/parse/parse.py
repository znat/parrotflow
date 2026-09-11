#!/usr/bin/env python3
"""The dependency parse of a dictation, printed. Changes no text.

    - name: parse
      description: print the dependency parse, for looking at
      command: /Users/…/ParrotFlow/python/bin/python3 parse.py
      returns: json

The interpreter is named by absolute path because an app launched from the
Dock inherits launchd's PATH — `/usr/bin:/bin:/usr/sbin:/sbin` — and the venv
`ParrotFlow --setup-parsing` builds is not on it.

Not in a pipeline. `spacy.load` costs 0.22s for English and 2.1s for French,
and a transform is a fresh process per dictation, so a stage that wants a
parse pays that on every one. Run it by hand:

    echo "so I went with john no with mark" | .../python3 parse.py --lang en

Four measurements say the parse does not help disfluency: it is a worse
generator than `noun_chunks`, it adds nothing to the detector, the "no arc
between them" test is at chance, and the "the cut broke the sentence" test
catches 16% of bad cuts. The one thing it earns is the dependency of a cue's
verb — `parataxis` means a clause repair, `ROOT` a phrase repair.
"""
import json
import os
import sys

MODELS = {"en": "en_core_web_sm", "fr": "fr_core_news_sm"}


def rows(doc):
    width = max((len(t.text) for t in doc), default=0)
    for token in doc:
        yield "  {:<{w}}  {:<6} {:<10} -> {}".format(
            token.text, token.pos_, token.dep_, token.head.text, w=width)


def main():
    lang = "en"
    if "--lang" in sys.argv:
        at = sys.argv.index("--lang")
        if at + 1 >= len(sys.argv):
            sys.stderr.write("--lang needs a value: %s\n" % ", ".join(MODELS))
            return 2
        lang = sys.argv[at + 1]
        if lang not in MODELS:
            # Falling back to English silently was worse than refusing: the
            # output looked like a French parse and was not one.
            sys.stderr.write("no model for %r — have: %s\n" % (lang, ", ".join(MODELS)))
            return 2

    structured = os.environ.get("PARROTFLOW_PROTOCOL") == "json"
    raw = sys.stdin.read()
    text = json.loads(raw)["text"] if structured else raw

    try:
        import spacy
    except ImportError:
        # Loud, not open. A stage whose interpreter is wrong must say so rather
        # than return the text and look like it worked.
        sys.stderr.write("no spacy — run: ParrotFlow --setup-parsing\n")
        return 1

    try:
        nlp = spacy.load(MODELS[lang])
    except OSError:
        # spaCy and its models are separate packages, so the import can succeed
        # while the model is absent.
        sys.stderr.write("no %s — run: ParrotFlow --setup-parsing\n" % MODELS[lang])
        return 1
    doc = nlp(text.strip())

    if structured:
        chunks = [c.text for c in doc.noun_chunks] if doc.has_annotation("DEP") else []
        print(json.dumps({
            "text": text,
            "vars": {"roots": sum(1 for t in doc if t.dep_ == "ROOT"),
                     "chunks": ", ".join(chunks)},
        }))
        return 0

    print("\n".join(rows(doc)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
