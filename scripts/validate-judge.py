#!/usr/bin/env python3
"""Score a judge against tests/judge-cases.yaml on a local Ollama model.

    scripts/validate-judge.py gemma4:e4b
    scripts/validate-judge.py gemma4:e4b --variant v2 --verbose
    scripts/validate-judge.py none --code-only     # the no-model control

The judge answers one question per proposed substitution: the vocabulary pass
wants to replace `heard` with `term` in this sentence — is that what the
speaker meant? It returns KEEP or DROP and nothing else. It never returns
text: a stage that can rewrite a transcript will, and this one runs on
dictations nobody has read yet.

Two numbers, because a single one hides the only failure that matters. The set
is 33% approve and 67% decline, so a judge that answers DROP to everything
scores 67% overall and is worthless. `approve` and `decline` are scored apart.

Scoreboard
                            approve  decline  overall  latency
    (fill in as measured)
"""
import argparse, json, os, pathlib, re, subprocess, sys, time, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CASES = ROOT / "tests" / "judge-cases.yaml"
ENDPOINT = "http://localhost:11434/api/chat"

# ---------------------------------------------------------------- variants

VARIANTS = {
    # v1 — the plainest statement of the job.
    "v1": """You check corrections made by a speech-to-text tool.

The tool replaced a word with a name from a list. Sometimes the speaker really
did say that name and it was misheard. Sometimes the speaker said an ordinary
word that merely sounds similar, and replacing it is wrong.

Read the sentence and decide.

Answer KEEP if the speaker meant the name.
Answer DROP if the speaker meant the original word.
Answer with one word: KEEP or DROP.""",

    # v2 — v1 plus the distinction stated as the question to ask. Named as a
    # variant rather than folded in, so the two can be compared.
    "v2": """You check corrections made by a speech-to-text tool.

The tool replaced a word with a name from a list. Ask one question: does the
original word make sense in this sentence?

If the original word is an ordinary English or French word that fits the
sentence, the tool is wrong — the speaker meant that word.
If the original word is not a real word, or makes no sense there, the tool is
right — it is a name the recogniser mangled.

Answer KEEP if the tool is right. Answer DROP if the tool is wrong.
Answer with one word: KEEP or DROP.""",

    # v3 — v2 with the answer tokens changed and nothing else. "KEEP" is
    # ambiguous about what is kept: the tool's replacement, or the word that
    # was there before. e4b answered DROP to all 51 cases under v1 and v2,
    # which is what reading it the second way looks like.
    "v3": """You check corrections made by a speech-to-text tool.

The tool replaced a word with a name from a list. Ask one question: does the
original word make sense in this sentence?

If the original word is an ordinary English or French word that fits the
sentence, the tool is wrong — the speaker meant that word.
If the original word is not a real word, or makes no sense there, the tool is
right — it is a name the recogniser mangled.

Was the tool right? Answer with one word: YES or NO.""",

    # v4 — a different question, not a different wording of the same one.
    # v1-v3 all asked "a tool made a correction, was it right?", which invites
    # scepticism of the tool; e4b answered NO to all 51 under every one of
    # them. This asks about the speaker instead, and tells the model the name
    # is one this person really uses — a prior the earlier prompts never gave.
    "v4": """The user dictates text, and the speech recogniser mangles names they
use often. You are given one sentence from a transcript, one word in it, and a
name from this user's own vocabulary that the word might really have been.

Decide from the sentence which the user meant.

If the word makes sense where it stands, they meant the word.
If the word is odd there, or is not a word at all, they meant the name.

Should the word be replaced with the name? Answer YES or NO.""",

    # v5 — v4 plus the rest of the user's vocabulary. Whether knowing the
    # neighbouring names helps the model place a sentence in that world, or
    # only gives it more strings to say yes to, is the thing this measures.
    "v5": """The user dictates text, and the speech recogniser mangles names they
use often. Their vocabulary includes: Arexvy, Matthieu, Mirza, Ollama, Praisy,
Redrock, Supabase, Tasmeen, Vercel — colleagues, products and tools they talk
about every day.

You are given one sentence from a transcript, one word in it, and the name from
that vocabulary the word might really have been.

Decide from the sentence which the user meant.

If the word makes sense where it stands, they meant the word.
If the word is odd there, or is not a word at all, they meant the name.

Should the word be replaced with the name? Answer YES or NO.""",
}

# Which words in a reply mean "the substitution should stand". Per variant,
# because the answer tokens are the thing v3 changes.
TOKENS = {
    "v1": ("KEEP", "DROP"), "v2": ("KEEP", "DROP"), "v3": ("YES", "NO"),
    "v4": ("YES", "NO"), "v5": ("YES", "NO"),
}

USER = """Sentence: {said}

The tool wants to replace "{heard}" with "{term}".
{question}"""

USER_SPEAKER = """The user said: "{said}"

The word "{heard}" might really be "{term}", from their vocabulary.
Should it be replaced? {question}"""


# ------------------------------------------------------------------ control

# A word the spell checker knows is a word the speaker meant. This is the
# no-model candidate, and it has to be written as well as the shipped thing —
# a strawman control proves nothing.
def code_only(said, heard, term):
    word = heard.strip(".,?!;:")
    if not word:
        return "KEEP"
    # A multi-word span glues into the term (`red rock` -> `Redrock`); that is
    # the compound case and the parts being real words is expected.
    if " " in word:
        glued = word.replace(" ", "")
        return "KEEP" if glued == term.lower() else "DROP"
    # Asked in the casing it was heard in, and lowercased. Case carries real
    # information here — the checker knows "Frederick" and not "frederick" —
    # but an ordinary word starting a sentence is capitalised too, so a hit in
    # either form means the speaker said a word rather than a mangled name.
    #
    # Except in caps. NSSpellChecker treats any all-caps run as an acronym and
    # accepts it: "XQZPT" comes back known. So a shouted word is judged only on
    # its lowercase form, or "OLAMA" would be read as a word nobody may touch.
    forms = [word.lower()] if word.isupper() else [word, word.lower()]
    return "DROP" if any(is_real_word(f) for f in forms) else "KEEP"


_spell_cache = {}

# NSSpellChecker rather than a word list, because that is what
# `Replacements.isRealWord` calls — a control measured against a different
# dictionary from the shipped one is measuring code nobody runs. Reached
# through `swift`, which has no Python binding here, so every word in the set
# is asked at once and the compile is paid once.
_SPELL_SWIFT = """import AppKit
let checker = NSSpellChecker.shared
for word in CommandLine.arguments.dropFirst() {
    let known = ["en", "fr"].contains { language in
        checker.checkSpelling(
            of: word, startingAt: 0, language: language,
            wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        ).location == NSNotFound
    }
    print("\\(word)\\t\\(known)")
}
"""


def warm_spell_cache(words):
    import tempfile
    words = sorted({w for w in words if w})
    if not words:
        return
    with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
        f.write(_SPELL_SWIFT)
        path = f.name
    try:
        out = subprocess.run(["swift", path, *words],
                             capture_output=True, text=True, timeout=180).stdout
        for line in out.splitlines():
            if "\t" in line:
                word, known = line.rsplit("\t", 1)
                _spell_cache[word] = known.strip() == "true"
    finally:
        pathlib.Path(path).unlink(missing_ok=True)


def is_real_word(word):
    return _spell_cache.get(word, False)


# -------------------------------------------------------------------- model

def ask(model, system, said, heard, term, tokens, speaker_framed=False):
    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": (
                USER_SPEAKER if speaker_framed else USER).format(
                said=said, heard=heard, term=term,
                question=f"{tokens[0]} or {tokens[1]}?")},
        ],
        "stream": False,
        "think": False,
        # One word out. A low cap costs nothing and bounds the damage when a
        # model starts explaining itself.
        "options": {"temperature": 0, "num_predict": 8},
    }).encode()
    req = urllib.request.Request(ENDPOINT, data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        reply = json.load(r)["message"]["content"]
    # Parse loosely. A model that answers "DROP." or "Answer: KEEP" has made
    # the decision and formatted it badly, and that is the parser's problem.
    upper = reply.upper()
    yes, no = tokens
    # `no` is checked first: "NO" is a substring of nothing here, but "YES"
    # contains no "NO" and a reply of "NO." must not fall through to "?".
    if no in upper and yes not in upper:
        return "DROP", reply
    if yes in upper and no not in upper:
        return "KEEP", reply
    return "?", reply


# --------------------------------------------------------------------- main

def load_shipped():
    """The judge as it ships, imported rather than reimplemented."""
    import importlib.util
    path = ROOT / "examples/transforms/verify_names/verify_names.py"
    spec = importlib.util.spec_from_file_location("verify_names", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The whole vocabulary, as the app passes it — not just the term in play. This
# is the difference v4->v5 measured at 47 points.
ALL_TERMS = ("Arexvy, Claude, Matthieu, Mirza, Ollama, Praisy, Redrock,"
             " Supabase, Tasmeen, Vercel")


def load_cases():
    text = CASES.read_text()
    blocks = re.findall(
        r'  - said: "(.*?)"\n    heard: "(.*?)"\n    term: "(.*?)"\n    expect: (\w+)',
        text, re.S)
    return [{"said": s, "heard": h, "term": t, "expect": e} for s, h, t, e in blocks]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--variant", default="v2")
    ap.add_argument("--code-only", action="store_true")
    # Score the file that ships, not a copy of its prompt in here. The two had
    # already drifted: the app judged the rewritten sentence while this asked
    # about the original, so 51/51 described code nobody ran.
    ap.add_argument("--script", action="store_true")
    ap.add_argument("--layout", default="split", choices=["split", "single"])
    ap.add_argument("--batch", default="off", choices=["on", "off"])
    ap.add_argument("--scheme", default="yn",
                    choices=["yn", "num2", "yn3", "num3", "num3x"])
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    cases = load_cases()
    system = VARIANTS.get(args.variant, "")
    if not args.code_only and args.variant not in VARIANTS:
        print(f"no variant {args.variant}; have {', '.join(VARIANTS)}")
        return 2

    if args.code_only:
        warm_spell_cache(
            form
            for c in cases if " " not in c["heard"]
            for form in (c["heard"].strip(".,?!;:"), c["heard"].strip(".,?!;:").lower())
        )

    all_terms = ALL_TERMS
    shipped = None
    if args.script:
        os.environ["PARROTFLOW_JUDGE_MODEL"] = args.model
        os.environ["PARROTFLOW_JUDGE_LAYOUT"] = args.layout
        os.environ["PARROTFLOW_JUDGE_BATCH"] = args.batch
        os.environ["PARROTFLOW_JUDGE_SCHEME"] = args.scheme
        shipped = load_shipped()
    want = {"approve": "KEEP", "decline": "DROP"}
    hits = {"approve": 0, "decline": 0}
    totals = {"approve": 0, "decline": 0}
    failures, elapsed = [], 0.0
    unsure, unsure_cases = 0, []

    for case in cases:
        totals[case["expect"]] += 1
        started = time.time()
        if args.code_only:
            got, raw = code_only(case["said"], case["heard"], case["term"]), ""
        elif args.script:
            if args.batch == "off" and args.scheme in ("yn", "yn3"):
                call = shipped.verdict(
                    case["said"], case["heard"], case["term"], all_terms,
                    app="", screen="")
                unsure += call == "unsure"
                if call == "unsure":
                    unsure_cases.append((case, want[case["expect"]]))
                keep = call == "yes"
            elif args.batch == "on":
                keep = shipped.verdicts(
                    case["said"], [(case["heard"], case["term"], None, None)],
                    all_terms, app="", screen="")[0]
            else:
                keep = shipped.approved(
                    case["said"], case["heard"], case["term"], all_terms,
                    app="", screen="")
            got, raw = ("KEEP" if keep else "DROP"), ""
        else:
            got, raw = ask(args.model, system, case["said"], case["heard"],
                           case["term"], TOKENS.get(args.variant, ("KEEP", "DROP")),
                           speaker_framed=args.variant in ("v4", "v5"))
        elapsed += time.time() - started

        ok = got == want[case["expect"]]
        hits[case["expect"]] += ok
        if not ok:
            failures.append((case, got, raw))
        if args.verbose:
            print(f"  {'ok  ' if ok else 'FAIL'} {case['heard']!r} -> {case['term']!r}"
                  f"  want {want[case['expect']]}, got {got}")

    total = sum(totals.values())
    score = sum(hits.values()) / total * 100
    label = ("code-only" if args.code_only
             else f"{args.model} batch/{args.scheme}" if args.script
             else f"{args.model} {args.variant}")
    print(f"\n{label}")
    for half in ("approve", "decline"):
        print(f"  {half:<8} {hits[half]}/{totals[half]}"
              f"  {hits[half]/max(totals[half],1)*100:.0f}%")
    print(f"  overall  {sum(hits.values())}/{total}  {score:.0f}%"
          f"   {elapsed/total:.2f}s per case")

    if unsure:
        would_be_wrong = sum(1 for c, w in unsure_cases if w == "KEEP")
        print(f"\n  unsure   {unsure}/{total} — of those, {would_be_wrong} were"
              f" really 'change' and {unsure - would_be_wrong}'leave'")
        for c, w in unsure_cases[:8]:
            print(f"    {c['heard']!r} -> {c['term']!r}  (truth: {w})")
            print(f"      {c['said'][:88]}")

    if failures and not args.verbose:
        print(f"\n  failures ({len(failures)}):")
        for case, got, raw in failures[:14]:
            print(f"    {case['heard']!r} -> {case['term']!r}"
                  f"  want {want[case['expect']]}, got {got}")
            print(f"      {case['said'][:96]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
