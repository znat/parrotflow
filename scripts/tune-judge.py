#!/usr/bin/env python3
"""Score a judge prompt against menus already harvested from the archive.

    scripts/tune-judge.py --harvest              # run the app once, cache the menus
    scripts/tune-judge.py                        # score the shipped verify_names.md
    scripts/tune-judge.py --prompt v6.md         # score a candidate
    scripts/tune-judge.py --prompt v6.md --model gemma4:12b
    scripts/tune-judge.py --strip-sentinels      # drop the fake 0.00 score lines

Harvesting is the slow part — every clip is decoded, and that is a second or
two each. It does not depend on the prompt, so it is done once and cached.
After that a variant costs one model call per case, which is what makes trying
six of them reasonable.

The number reported is **picked**: of the menus that held the true sentence,
how many the model chose. Menus that never held it are counted separately and
excluded — a prompt cannot be blamed for an option that was not on the list,
and leaving them in hides the difference between prompts behind a constant.

`chance` is printed beside it — what guessing one letter would score on these
menu sizes. Half the cached menus hold two options, so guessing gets 8.1/28,
not the 2 that a menu of sixteen would suggest. A total with no chance beside
it says nothing (F13).
"""
import argparse
import json
import os
import re
import string
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "tests/judge-menus.json"
PROMPT = ROOT / "examples/prompts/verify_names.md"
CLIPS = Path.home() / "Recordings/ParrotFlow Dev"
ENDPOINT = os.environ.get("PARROTFLOW_LLM_ENDPOINT", "http://localhost:11434") + "/api/chat"

sys.path.insert(0, str(ROOT / "scripts"))
from importlib.machinery import SourceFileLoader

recall = SourceFileLoader("recall", str(ROOT / "scripts/menu-recall.py")).load_module()
# The freshly built app, resolved the same way `menu-recall.py` resolves it.
# This file used to name /Applications outright, so a harvest ran the installed
# binary while every other measurement ran the built one — and it cached six
# menus where there were thirty-two.
APP = recall.APP


def harvest():
    cases = []
    for wav, said in recall.load_cases():
        if not said:
            continue
        dump = Path(tempfile.mkdtemp()) / "menu.txt"
        environment = dict(os.environ, PARROTFLOW_JUDGE_DUMP=str(dump))
        subprocess.run([APP, "--transcribe", str(CLIPS / wav)],
                       capture_output=True, text=True, env=environment, timeout=180)
        if not dump.exists():
            continue
        text = dump.read_text()
        system = re.search(r"^SYSTEM (.*)$", text, re.M)
        menu = [m.group(1) for m in re.finditer(r"^MENU [A-Z]\. (.*)$", text, re.M)]
        block = re.search(r"^SCORES (.*)$", text, re.M)
        if len(menu) < 2:
            continue
        cases.append({
            "wav": wav, "said": said, "menu": menu,
            "terms": re.search(r"includes: (.*?) —", system.group(1)).group(1)
            if system and "includes: " in system.group(1) else "",
            "scores": block.group(1).replace("\\n", "\n") if block else "",
        })
        print(f"  {wav}  {len(menu)} options", file=sys.stderr)
    CACHE.write_text(json.dumps(cases, indent=1, ensure_ascii=False))
    print(f"\ncached {len(cases)} menus to {CACHE.relative_to(ROOT)}", file=sys.stderr)


STRAY = []   # replies whose first character was not the answer

# One line of the score block: two spellings for one stretch of audio, each
# with its score in nats. The first number is the *heard* score — what the
# decoder actually wrote.
SCORE_LINE = re.compile(r'"([^"]*)"\s+(-?\d+\.\d+)\s+"([^"]*)"\s+(-?\d+\.\d+)')
SENTINEL_LINE = re.compile(r'^\s*"[^"]*"\s+0\.00\s')


def strip_sentinels(block):
    """Drop score lines whose heard score is the 0.00 sentinel (F6).

    A spotter-only proposal has no heard score. The prototype writes zero for
    it, and the block then reads as a measurement: `"his" 0.00 "Praisy" -3.88
    — "Praisy" heard 3.9 less clearly` claims the recogniser heard "his"
    perfectly, which nothing measured. 10 of the 33 cached menus carry one.

    Zero is also a legal best score in nats, so a real zero cannot be told
    from the sentinel here. That is why this is a flag on the harness and not
    a fix: PR 3 removes the sentinel at the source, and then this flag has
    nothing to do.

    If every score line goes, the preamble is left promising numbers that are
    not there, so the whole block goes with them.
    """
    if not block:
        return ""
    kept = [line for line in block.splitlines() if not SENTINEL_LINE.match(line)]
    if not any(SCORE_LINE.search(line) for line in kept):
        return ""
    return "\n".join(kept)


def ask(model, system, options, scores="", logprobs=False, lead=""):
    """The judge's choice, either sampled or read off the letter distribution.

    Sampling keeps only the winner. `logprobs` asks Ollama (0.32+) for the
    distribution over the first token instead, which costs the same call and
    returns a ranking with margins — and is immune to the failure below.

    The sampled path reads the letter with `chosen`, which is the app's own
    rule. Replies that did not begin with a bare letter are collected in STRAY
    so the size of that effect is visible rather than assumed.

    `lead` goes above the lettered options. The app sends nothing there — the
    menu is whole sentences, so the sentence is already in every option.
    `judge-routing.py` puts the sentence with a blank in it, and needs the
    reply read by the same rule as every other arm.
    """
    body = "\n".join(f"{string.ascii_uppercase[i]}. {o}" for i, o in enumerate(options))
    payload = {
        "model": model, "stream": False, "think": False,
        "options": {"temperature": 0, "num_predict": 8},
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": lead + body + scores + "\n\nWhich letter?"}],
    }
    if logprobs:
        payload |= {"logprobs": True, "top_logprobs": 20}
    request = urllib.request.Request(
        ENDPOINT, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        answer = json.loads(response.read())
    reply = answer["message"]["content"].strip()

    if logprobs and answer.get("logprobs"):
        ranked = ranking(answer["logprobs"][0].get("top_logprobs", []), options)
        return ranked[0][1] if ranked else None

    if not reply[:1].isalpha():
        STRAY.append(reply)
    index = chosen(reply, len(options))
    return None if index is None else options[index]


def chosen(reply, count):
    """The letter a reply names, read exactly as the app reads it.

    This is `VocabularyJudge.chosen` in Sources/, in Python. The two must agree:
    a harness that reads "Option B" as O while the app reads it as B is scoring
    a choice the app never made, and every baseline in this file would then
    describe a judge nobody ships.

    A letter standing on its own is the answer. `I` goes last among those,
    because it is the one letter of the alphabet that is also an English word —
    "I pick B" is B. A reply whose only bare letter is `I` still answers `I`.
    Apostrophes count as letters for the cut, so "I'd pick D" is D.

    The first letter anywhere is the fallback, for a reply with no bare letter
    in it at all.
    """
    upper = reply.upper()
    words = re.split(r"[^A-Z'\u2019]+", upper)
    named = [string.ascii_uppercase.index(w) for w in words
             if len(w) == 1 and w in string.ascii_uppercase
             and string.ascii_uppercase.index(w) < count]
    for index in named:
        if string.ascii_uppercase[index] != "I":
            return index
    if named:
        return named[0]
    for character in upper:
        if character in string.ascii_uppercase:
            index = string.ascii_uppercase.index(character)
            if index < count:
                return index
    return None


def ranking(top, options):
    """The letters in the first-token distribution, best first, as options.

    Ollama returns whatever the model might have said — words, punctuation,
    whitespace. Only entries that are a single letter naming an option on this
    menu mean anything, and the rest are dropped rather than ranked.
    """
    out = []
    for entry in top:
        token = entry["token"].strip()
        # `isalpha` is true of "é" and of Cyrillic, which are not menu letters
        # and are not in `ascii_uppercase` — asking for their index raises.
        if len(token) != 1 or token.upper() not in string.ascii_uppercase:
            continue
        index = string.ascii_uppercase.index(token.upper())
        if index < len(options):
            out.append((entry["logprob"], options[index]))
    return sorted(out, reverse=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--harvest", action="store_true")
    ap.add_argument("--prompt", default=str(PROMPT))
    ap.add_argument("--model", default=os.environ.get("PARROTFLOW_JUDGE_MODEL", "gemma4:e4b"))
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--no-scores", action="store_true",
                    help="withhold the acoustic block, to measure what it is worth")
    ap.add_argument("--strip-sentinels", action="store_true",
                    help="drop score lines whose heard score is 0.00 (F6)")
    ap.add_argument("--logprobs", action="store_true",
                    help="read the letter distribution instead of sampling one")
    args = ap.parse_args()

    if args.harvest:
        harvest()
        return 0
    if not CACHE.exists():
        print("✗ no cache — run with --harvest first")
        return 2

    prompt = Path(args.prompt).read_text().strip()
    cases = json.loads(CACHE.read_text())
    scored = picked = unreachable = stripped = 0
    chance = 0.0
    for case in cases:
        truth = recall.normalise(case["said"])
        if truth not in [recall.normalise(o) for o in case["menu"]]:
            unreachable += 1
            continue
        scored += 1
        chance += 1 / len(case["menu"])
        block = "" if args.no_scores else (case.get("scores") or "")
        if args.strip_sentinels and block:
            trimmed = strip_sentinels(block)
            stripped += trimmed != block
            block = trimmed
        chosen = ask(args.model, prompt.replace("{terms}", case["terms"]), case["menu"],
                     block, logprobs=args.logprobs)
        right = chosen is not None and recall.normalise(chosen) == truth
        picked += right
        if args.verbose and not right:
            print(f"  ✗ {case['wav']}  {len(case['menu'])} options")
            print(f"      said:  {case['said']}")
            print(f"      chose: {chosen}")

    name = Path(args.prompt).name
    how = "logprob" if args.logprobs else "sampled"
    shown = "none" if args.no_scores else ("stripped" if args.strip_sentinels else "full")
    lead = f"  {name:<20} {args.model:<14} {how:<8} scores {shown:<9}"
    print(f"\n{lead}picked {picked}/{scored}"
          f"   ({unreachable} menu(s) never held the answer)")
    # What guessing one letter would score on these menu sizes. Half of them
    # hold two options, so it is not 1/16 per case. A total printed without
    # this line is unreadable (F13).
    print(f"{'  chance':<{len(lead)}}guess  {chance:.1f}/{scored}")
    if args.strip_sentinels:
        print(f"  {stripped} menu(s) had a 0.00 score line removed")
    if STRAY:
        print(f"  {len(STRAY)} reply(s) did not start with a letter, so the first"
              f" letter of a word was read as the answer: {STRAY[:3]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
