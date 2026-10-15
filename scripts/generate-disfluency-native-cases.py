#!/usr/bin/env python3
"""Write tests/disfluency-native-cases.json from `collapse()` in disfluency.py.

    scripts/generate-disfluency-native-cases.py
    scripts/generate-disfluency-native-cases.py --extra lines.txt --out /tmp/x.json

The inputs are repo text (case sets, docs) plus variants made from it with a
fixed seed. Each case holds what the Python string rules return, with no spaCy:
the native stage in Swift must return the same, and
scripts/check-disfluency-native.sh checks that it does.

`--extra` adds one input per line of a file, for a local run on text that may
not be committed.
"""
import argparse
import glob
import importlib.util
import json
import random
import re
import sys
import unicodedata
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "built-in/transforms/disfluency/disfluency.py"
OUT = ROOT / "tests/disfluency-native-cases.json"
SEED = 20261014
DOC_SENTENCES = 300
# How the native stage's `declined` starts when a correction is said and the
# parser will not load, which is how the check runs it.
DECLINED = "corrections: the parser did not load"
# Disfluency.correctionMarkers and the restart commands: the native stage asks
# the parser only when one of these is said, in a text that reads as English.
CUES = [c.split() for c in (
    "i mean", "i meant", "no", "sorry", "or rather", "wait", "actually",
    "scratch that", "strike that", "let me rephrase", "let me rephrase that",
    "let me restart", "let me start over", "let me start again", "let me try again",
    "let me say that again", "start over",
)]
# Disfluency.englishWords.
ENGLISH = {
    "the", "to", "with", "and", "is", "it", "you", "of", "for", "that", "we", "my", "this", "be", "are",
    "was", "in", "have", "do", "not", "can", "will", "i", "i'm", "it's", "what", "at", "he", "she", "they",
    "but", "just", "from", "your", "our", "if", "so", "his", "him", "her", "them", "us", "their", "were",
    "been", "has", "had", "would", "could", "should", "don't", "i'll", "we'll", "that's", "who", "how",
    "there", "about", "up", "out", "please", "let", "let's", "send", "call", "need", "want", "tell", "ask",
    "use", "put", "move", "open", "check", "get", "make", "take", "meet", "book", "set", "add",
}

_spec = importlib.util.spec_from_file_location("disfluency", SOURCE)
disfluency = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(disfluency)



def says_correction(text):
    words = [disfluency.bare(w.group()) for w in disfluency.WORD.finditer(text)]
    english = sum(w in ENGLISH for w in words)
    if english == 0 or english * 100 < len(words) * 10:
        return False
    return any(words[i:i + len(cue)] == cue for i in range(len(words)) for cue in CUES)


def reference(text):
    """`clean()` on a Mac without spaCy, for English."""
    applied = []
    out = disfluency.collapse(text, applied)
    case = {"input": text}
    if out != text:
        case["text"] = out
    if applied:
        case["applied"] = ", ".join(dict.fromkeys(applied))
        case["edits"] = len(applied)
    if says_correction(out):
        case["declined"] = DECLINED
    return case


def case_set_text():
    found = []

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key in ("input", "text") and isinstance(value, str):
                    found.append(value)
                else:
                    walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    files = sorted(glob.glob(str(ROOT / "tests/*.yaml")) + glob.glob(str(ROOT / "tests/*.json"))
                   + glob.glob(str(ROOT / "built-in/transforms/*/cases.yaml")))
    disfluency_cases = str(ROOT / "built-in/transforms/disfluency/cases.yaml")
    files.remove(disfluency_cases)
    for path in [disfluency_cases] + files:
        # The corrections need the parser, which this check never loads.
        if path.endswith(("disfluency-native-cases.json", "disfluency-corrections-cases.yaml")):
            continue
        with open(path, encoding="utf-8") as handle:
            walk(json.load(handle) if path.endswith(".json") else yaml.safe_load(handle))
    return found


def doc_sentences():
    found = []
    for path in sorted(glob.glob(str(ROOT / "docs/**/*.md"), recursive=True)):
        text = Path(path).read_text(encoding="utf-8")
        text = re.sub(r"```.*?```", " ", text, flags=re.S)
        text = re.sub(r"`[^`]*`", " ", text)
        text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
        for line in text.splitlines():
            if line.lstrip().startswith(("|", "#", "<", ">")):
                continue
            for sentence in re.split(r"(?<=[.!?])\s+", line.strip(" -*")):
                if 20 <= len(sentence) <= 200 and re.search(r"[a-z]{3}", sentence):
                    found.append(sentence)
    return found


FRENCH = [
    "vous vous êtes trompé de dossier",
    "il il a acheté une voiture",
    "je je pense que c'est c'est bon",
    "on a a fini le le travail",
    "peut peut-être demain, demain matin",
    "nous nous sommes vus à à Paris",
    "c'est le le pro le problème du du serveur",
    "deux deux trois quatre",
    "il y a y a un souci",
    "très très bien, merci merci",
    "j'ai j'ai envoyé le mail à Hélène",
    "Est-ce que tu tu peux regarder ça ?",
    "la la la, on chante",
    "le dé le déploiement est est prêt",
    "co co comment ça marche",
]

ODD = [
    "the the café café opened",
    "2×3 2×3 is six",
    "ΣΟΦΟΣ ΣΟΦΟΣ σοφος σοφος",
    "İstanbul İstanbul is big",
    "Straße Straße ist lang",
    "ﬁle ﬁle names",
    "the the 👍 prompt",
    "👨‍👩‍👧 family family photo",
    "I I can't can't do it",
    "it it's fine, we we're done",
    "it it’s fine, we we’re here",
    "pr proposed the pr pr change",
    "the ter the terminal 🇫🇷 opens",
    "a a test with no-break spaces",
    "the\tthe tab case",
    "Ünïcödé Ünïcödé wörds",
    "été été decomposed",
    "été été composed",
    "snake_case snake_case names",
    "B. b. bananas and a a apples",
    "w we can try",
    "I mean w we can try",
    "co could you check",
    "in the ter in the terminal",
    "you know, you know, it works",
    "Like like I said",
    "ı mean it, İ MEAN it",
    "you Know the drill",
    "x.y x.y names",
    "Ok. Ok. Fine",
    "done… done",
    "one one two two",
    "3 3 apples and 4 4 pears",
    "A A B B C C",
    "a b a b c",
]

# "I I" as a stutter and as the letter: both ports must agree on each.
LETTER_I = [
    "World War I I think ended in 1918.", "Henry I I was king.", "Use option I I guess.",
    "My initials are I I.", "Press I I to toggle.", "Type A I I B.", "The letters are A, I, I, B.",
    "I I I think so.", "and I I mean it", "I, I want to go.", "so, I I guess it works",
]

# Characters Python 3.10 (Unicode 13) and Swift agree on, plus the ones the
# rules treat specially. No scalar assigned after Unicode 13.
SOUP = list("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") + list(
    "      .,!?…'’-_;:()\"\n\t") + list("éèêàôüçÉÀßøñ×÷") + [
    "́", "̀", " ", "‍", "️", "👍", "🇫🇷", "😀", "Σ", "σ", "ς",
    "İ", "ı", "K", "ǅ", "ǈ", "ŉ", "ﬁ", "²", "½", "٣", "한", "ᄀ", "ᅡ",
    " the ", " a ", " I ", " co", " could ", " in the ", " ter", " you know ", " like ",
]


def words_of(text):
    return list(disfluency.WORD.finditer(text))


def splice(text, at, insert):
    return text[:at] + insert + text[at:]


def mutate(text, rng):
    words = words_of(text)
    if not words:
        return text
    kind = rng.choice(["word", "phrase", "triple", "fragment", "partial", "restart",
                       "word", "partial", "restart", "two"])
    i = rng.randrange(len(words))
    w = words[i]
    gap = rng.choice([" ", " ", " ", ", ", ". ", "... ", " - ", "? ", "  "])
    if kind == "word":
        copy = w.group()
        if rng.random() < 0.3:
            copy = copy.capitalize() if copy[:1].islower() else copy.lower()
        return splice(text, w.start(), copy + gap)
    if kind == "triple":
        return splice(text, w.start(), (w.group() + " ") * 2)
    if kind == "phrase":
        n = rng.randint(2, 4)
        run = words[i:i + n]
        return splice(text, run[0].start(), text[run[0].start():run[-1].end()] + gap)
    if kind == "fragment":
        return splice(text, w.start(), w.group()[0].lower() + " ")
    if kind == "partial":
        word = w.group()
        if len(word) < 3:
            return splice(text, w.start(), word + " ")
        return splice(text, w.start(), word[:rng.randint(2, len(word) - 1)] + gap)
    if kind == "restart":
        n = rng.randint(2, 4)
        run = words[i:i + n]
        last = run[-1].group()
        cut = last[:max(2, rng.randint(1, max(1, len(last) - 1)))]
        return splice(text, run[0].start(), text[run[0].start():run[-1].start()] + cut + gap)
    return mutate(mutate(text, rng), rng)


def dress(text, rng):
    kind = rng.choice(["upper", "title", "accent", "emoji", "nfd", "quote", "digits",
                       "space", "none", "none", "none", "none"])
    if kind == "upper":
        return text.upper()
    if kind == "title":
        return text.title()
    if kind == "accent":
        return text.replace("e", "é", 2).replace("o", "ô", 1)
    if kind == "emoji":
        words = words_of(text)
        if not words:
            return text
        w = rng.choice(words)
        return splice(text, w.end(), rng.choice([" 👍", "😀", " 🇫🇷 ", "👨‍👩‍👧"]))
    if kind == "nfd":
        return unicodedata.normalize("NFD", text)
    if kind == "quote":
        return text.replace("'", "’")
    if kind == "digits":
        return text.replace(" two ", " 2 ").replace(" one ", " 1 1 ")
    if kind == "space":
        return text.replace(" ", rng.choice([" ", "\t", "  ", "\n"]), 1)
    return text


def soup(rng):
    return "".join(rng.choice(SOUP) for _ in range(rng.randint(3, 40)))


def long_dictation(sentences, rng):
    parts = []
    while sum(len(p) for p in parts) < 3000:
        parts.append(dress(mutate(rng.choice(sentences), rng), rng))
    return " ".join(parts)


def inputs(extra):
    rng = random.Random(SEED)
    base = case_set_text()
    docs = doc_sentences()
    base += random.Random(SEED).sample(docs, min(DOC_SENTENCES, len(docs)))
    base += FRENCH + ODD
    made = list(base)
    for text in base:
        made.append(dress(mutate(text, rng), rng))
    made += [soup(rng) for _ in range(300)]
    made += [long_dictation(docs, rng) for _ in range(5)]
    # After every draw from rng, so adding to it moves no other case.
    made += LETTER_I
    made += extra
    seen = set()
    kept = []
    for text in made:
        # `--pipeline` reads a text starting with "--" as a missing one, and
        # runs no transform on "hey parrot", a spoken command.
        folded = "".join(c for c in unicodedata.normalize("NFKD", text.lower())
                         if not unicodedata.combining(c))
        if not text.strip() or text.startswith("--") or "parrot" in folded or text in seen:
            continue
        seen.add(text)
        kept.append(text)
    return kept


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extra", help="a file with one more input per line")
    parser.add_argument("--only-extra", action="store_true", help="write only the --extra inputs")
    parser.add_argument("--out", default=str(OUT))
    args = parser.parse_args()
    extra = []
    if args.extra:
        extra = [line for line in Path(args.extra).read_text(encoding="utf-8").splitlines() if line]
    texts = extra if args.only_extra else inputs(extra)
    cases = [reference(text) for text in texts]
    header = {
        "source": "built-in/transforms/disfluency/disfluency.py collapse(), no spaCy, language en",
        "python": sys.version.split()[0],
        "unicode": unicodedata.unidata_version,
    }
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(header, ensure_ascii=False)[:-1] + ', "cases": [\n')
        handle.write(",\n".join(json.dumps(c, ensure_ascii=False) for c in cases))
        handle.write("\n]}\n")
    changed = sum(1 for c in cases if "text" in c)
    print(f"{len(cases)} cases, {changed} changed, written to {args.out}")


if __name__ == "__main__":
    main()
