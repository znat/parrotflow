#!/usr/bin/env python3
"""Derive per-term similarity floors from a person's own voice.

    scripts/calibrate.py confusables Vercel Praisy Tasmeen
    scripts/calibrate.py score calibration.yaml

A vocabulary floor is a bet about two distributions: how far a speaker's
rendering of a name lands from its spelling, and how close the ordinary words
that sound like it land. Both are properties of a mouth, not of a dictionary,
so both have to be measured on the person who will use the config.

`confusables` finds the words each term can be confused with. Claude writes
sentences around them — that is a judgement, not a lookup, and the sentences
have to sound like something a person would say with the term buried mid-
clause rather than announced.

`score` pairs the recordings against the sentences, re-decodes each with the
vocabulary **off**, and reports the band:

    Vercel
      said "Vercel"       lands at   0.67 .. 1.00
      said a confusable   lands at   0.30 .. 0.50
      band 0.50 .. 0.67   ->  floor 0.58

A wide band means the speaker separates the two clearly and the floor is
uncritical. A band that closes means no floor exists and the term needs a rule
or the judge. That difference is the point: it is the measurement that tells a
non-native speaker which of their terms will never be safe acoustically.
"""
import argparse, json, os, pathlib, re, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
# The words a person is plausibly going to say, by usage frequency — not every
# word ever printed. `/usr/share/dict/words` is web2, 234k entries deep in the
# archaic, and using it sets floors against words nobody says: `Vercel`
# collides with `vervel`, a strap on a hawk's leg, at 0.83, and a floor above
# that would refuse `Versal`, the mishearing that actually happens.
#
# One file per language, and only the ones a person actually dictates in are
# read. A term is only in danger from words its speaker says: `Praisy` collides
# with the French `prises` and the English `praise`, and someone who dictates
# only in English should not have their floor raised by the first.
WORDS = ROOT / "data"
FALLBACK_WORDS = pathlib.Path("/usr/share/dict/words")


def word_lists(languages):
    """The frequency lists for these languages, or web2 if none are shipped."""
    found = [WORDS / f"common-words-{code}.txt" for code in languages]
    found = [path for path in found if path.exists()]
    return found or ([FALLBACK_WORDS] if FALLBACK_WORDS.exists() else [])


# ------------------------------------------------------------------ distance

def levenshtein(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(cur[-1] + 1, prev[j] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def similarity(a, b):
    """The gate's own metric, spaces removed so compounds compare glued."""
    a = a.lower().replace(" ", "")
    b = b.lower().replace(" ", "")
    if not a or not b:
        return 0.0
    return 1 - levenshtein(a, b) / max(len(a), len(b))


# --------------------------------------------------------------- confusables

# Verb-particle pairs that glue into real nouns. A term shaped like one is
# unsafe however clean its dictionary neighbourhood looks: `Turndown` has no
# single-word collision and still eats "turn down the volume".
GLUED_PHRASES = [
    "turn down", "turn up", "back end", "front end", "set up", "check out",
    "log in", "log out", "time out", "hand off", "roll back", "fall back",
    "work around", "stand up", "break down", "hold up", "line up", "left over",
    "make up", "take over", "look up", "drop off", "pick up", "run time",
]


def confusables(term, languages=("en", "fr"), limit=8):
    """Ordinary words and phrases within reach of `term`, closest first.

    Only the languages given are searched, so the answer is about the words
    this speaker says rather than about every word in print.
    """
    target = term.lower()
    found, seen = [], set()
    for source in word_lists(languages):
        with source.open() as handle:
            for line in handle:
                word = line.strip().lower()
                if not word or word == target or word in seen:
                    continue
                if abs(len(word) - len(target)) > 3:
                    continue
                score = similarity(word, target)
                if score >= 0.55:
                    seen.add(word)
                    found.append((score, word))
    for phrase in GLUED_PHRASES:
        score = similarity(phrase, target)
        if score >= 0.55:
            found.append((score, phrase))
    found.sort(reverse=True)
    return found[:limit]


# ------------------------------------------------------------------ scoring

def transcribe(app, path):
    """Decode one clip with the vocabulary off — what the recogniser heard."""
    out = subprocess.run([app, "--transcribe", str(path), "--no-vocab"],
                         capture_output=True, text=True, timeout=300).stdout
    plain = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", out)
    lines = [l.strip() for l in plain.replace("\r", "\n").splitlines()]
    for i, line in enumerate(lines):
        if "── transcript" in line:
            return lines[i + 1] if i + 1 < len(lines) else ""
    return ""


def rendering_of(target, heard, said):
    """The words in `heard` standing where `target` stood in `said`.

    By position, not by similarity. A rendering that looks nothing like the
    term is exactly the one that decides whether a floor can reach it, so it
    must not be filtered out by the thing being measured.
    """
    if target not in said:
        return heard
    before, _, after = said.partition(target)
    lead = re.findall(r"[\w'À-ÿ]+", before)[-2:]
    trail = re.findall(r"[\w'À-ÿ]+", after)[:2]
    words = re.findall(r"[\w'À-ÿ]+", heard)
    low = [w.lower() for w in words]

    start = 0
    for anchor in reversed(lead):
        if anchor.lower() in low:
            start = low.index(anchor.lower()) + 1
            break
    end = len(words)
    for anchor in trail:
        if anchor.lower() in low[start:]:
            end = low.index(anchor.lower(), start)
            break
    return " ".join(words[start:end]) or "(nothing)"


def overlap(expected, heard):
    """Fraction of the sentence's words that turned up in the transcript."""
    want = {w.lower() for w in re.findall(r"[\w'À-ÿ]+", expected)}
    got = {w.lower() for w in re.findall(r"[\w'À-ÿ]+", heard)}
    return len(want & got) / max(len(want), 1)


def recent_recordings(directory, count):
    clips = sorted(pathlib.Path(directory).glob("parrotflow-*.wav"))
    return clips[-count:]


def score_manifest(manifest_path, app, directory):
    manifest = json.loads(pathlib.Path(manifest_path).read_text())
    sentences = manifest["sentences"]
    clips = recent_recordings(directory, len(sentences))
    if len(clips) < len(sentences):
        print(f"✗ {len(sentences)} sentences but only {len(clips)} recordings in"
              f" {directory}")
        return 1

    print(f"pairing {len(clips)} recordings with {len(sentences)} sentences,"
          " oldest first\n")
    landings, suspect = {}, []
    for entry, clip in zip(sentences, clips):
        heard = transcribe(app, clip)
        # Pairing by order breaks the moment somebody re-reads a line, and a
        # mispaired clip does not fail — it produces a confident floor from two
        # unrelated sentences. So check that the words either side of the term
        # actually turned up before trusting anything derived from this clip.
        if overlap(entry["text"], heard) < 0.5:
            suspect.append((clip.name, entry["text"], heard))
            continue
        # Several targets per sentence. Reading twelve sentences instead of
        # forty is the difference between a setup someone finishes and one they
        # abandon, and nothing about the measurement needs one word per clip.
        for target in entry["targets"]:
            got = rendering_of(target["word"], heard, entry["text"])
            term = target["against"]
            landed = similarity(got, term)
            landings.setdefault(term, {"term": [], "confusable": []})
            landings[term][target["kind"]].append((landed, target["word"], got))
            print(f"  {clip.name}  {target['word']!r} -> {got!r}"
                  f"  ({landed:.2f} vs {term})")

    if suspect:
        print(f"\n  ✗ {len(suspect)} recording(s) do not match their sentence."
              " Read those again, or fix the order:")
        for name, expected, heard in suspect:
            print(f"      {name}")
            print(f"        expected: {expected[:70]}")
            print(f"        heard:    {heard[:70]}")
        print("\n  Nothing is derived from those; the floors below use the rest.")

    print("\n── floors ─────────────────────────────────────────────")
    emitted = {}
    for term, sides in landings.items():
        mine = [value for value, _, _ in sides["term"]]
        theirs = [value for value, _, _ in sides["confusable"]]
        if not mine:
            continue
        lowest, highest = min(mine), max(theirs) if theirs else 0.0
        print(f"\n  {term}")
        print(f"    your renderings land at   {min(mine):.2f} .. {max(mine):.2f}")
        if theirs:
            print(f"    confusables land at       {min(theirs):.2f} .. {highest:.2f}")
        if lowest > highest:
            floor = round((lowest + highest) / 2, 2)
            emitted[term] = floor
            print(f"    band {highest:.2f} .. {lowest:.2f}   ->  floor {floor}")
        else:
            missed = [word for value, word, _ in sides["confusable"] if value >= lowest]
            emitted[term] = None
            print(f"    NO BAND — {', '.join(missed)} land as close as your own"
                  f" renderings.\n      No floor works. Use a rule, or the judge.")

    print("\n── config ─────────────────────────────────────────────\n")
    for term, floor in sorted(emitted.items()):
        if floor is None:
            heard = sorted({got for _, _, got in landings[term]["term"]})
            print(f"    {term}:")
            print(f"      floor: off")
            print(f"      heard: [{', '.join(heard)}]")
        else:
            print(f"    {term}: {floor}")
    return 0


# --------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)

    find = sub.add_parser("confusables")
    find.add_argument("terms", nargs="+")
    find.add_argument("--lang", default="en,fr",
                      help="languages the speaker dictates in, e.g. en or en,fr")

    run = sub.add_parser("score")
    run.add_argument("manifest")
    run.add_argument("--app", default=str(
        ROOT / ".build/ParrotFlowDev.app/Contents/MacOS/ParrotFlow"))
    run.add_argument("--recordings", default=str(
        pathlib.Path.home() / "Recordings/ParrotFlow Dev"))

    args = ap.parse_args()
    if args.command == "confusables":
        languages = [c.strip() for c in args.lang.split(",") if c.strip()]
        for term in args.terms:
            near = confusables(term, languages)
            print(f"\n{term}")
            if not near:
                print(f"  nothing within 0.55 in {'/'.join(languages)}"
                      " — safe at any floor")
            for value, word in near:
                print(f"  {value:.2f}  {word}")
        return 0
    return score_manifest(args.manifest, args.app, args.recordings)


if __name__ == "__main__":
    sys.exit(main())
