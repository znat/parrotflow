#!/usr/bin/env python3
"""Score the slot-shaped judge: one call per sentence, options per ambiguous word.

    scripts/validate-slots.py gemma4:e4b slots.json
    scripts/validate-slots.py gemma4:12b slots.json --glossary

The shipped judge asks one yes/no per proposal, so it never learns that `Mirza`
and `Praisy` are competing for the same half-second, and "leave it alone" is
only reachable by refusing a leading question. This asks once per sentence,
marks every ambiguous word, and lists what it could be — the word as heard
first, then the vocabulary terms the spotter found over that span.

    So [[1]] and [[2]] goes to the movies ...

    1. heard "Myrza" — Myrza | Mirza | Ollama | Vercel
    2. heard "Mirra" — Mirra | Praisy | Ollama

Scored per slot, and separately on the slots whose answer is the heard word
(most of them) against the slots where a term is right — a judge that keeps
every word scores well on the first and nothing on the second.
"""
import argparse, json, os, pathlib, re, sys, time, urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
ENDPOINT = "http://localhost:11434/api/chat"

# What each name is. Measured as a variant rather than assumed: a small model
# has no way to know that Vercel is a deployment platform and Versailles is a
# palace, and that is exactly the distinction the sentence turns on.
GLOSSARY = {
    "Arexvy": "a vaccine brand",
    "Claude": "an AI assistant the speaker works in all day",
    "Matthieu": "a teammate",
    "Mirza": "a teammate",
    "Ollama": "software for running language models locally",
    "Praisy": "a teammate",
    "Redrock": "an internal project",
    "Supabase": "a hosted database platform",
    "Tasmeen": "a teammate",
    "Vercel": "an application deployment platform",
}

SYSTEM = """The user dictates text and the speech recogniser mangles the names
they use often. Some words in the transcript below are ambiguous: each one is
marked, and you are given what the recogniser wrote and the names it might
really have been.

For each marked word, choose what the user actually said. The first option is
always the word as the recogniser wrote it — choose it whenever the word makes
sense where it stands. Choose a name only when the word is odd there, or is not
a word at all.

The marked words are in one sentence and are related: if two of them are people
in the same clause, that is a reason to read them the same way.

Most marked words are already correct. A name is offered only because it sounds
faintly similar, not because it is likely — in a typical sentence every marked
word turns out to be the word the recogniser wrote. Choose a name only when the
word as written makes no sense in the sentence."""

SYSTEM_PLAIN = SYSTEM

ASK = """
Answer with one line per marked word, in order:
{template}

Nothing else."""


def slot_prompt(case, glossary):
    said = case["said"]
    slots = case["slots"]
    marked = said
    # Mark from the back so earlier offsets stay valid.
    for n, slot in reversed(list(enumerate(slots, 1))):
        heard = slot["heard"]
        at = marked.rfind(heard)
        if at >= 0:
            marked = marked[:at] + f"[[{n}]]" + marked[at + len(heard):]

    lines = []
    for n, slot in enumerate(slots, 1):
        options = [slot["heard"]] + slot["candidates"]
        described = []
        for option in options:
            note = glossary.get(option)
            described.append(f"{option} ({note})" if note else option)
        lines.append(f'{n}. the recogniser wrote "{slot["heard"]}" — '
                     + " | ".join(described))

    template = "\n".join(f"{n}=<your choice>" for n in range(1, len(slots) + 1))
    return (f"{marked}\n\n" + "\n".join(lines)
            + "\n" + ASK.format(template=template))


def ask(model, system, user, slots):
    body = json.dumps({
        "model": model,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user}],
        "stream": False, "think": False,
        "options": {"temperature": 0, "num_predict": 12 * slots + 16},
    }).encode()
    request = urllib.request.Request(
        ENDPOINT, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=180) as response:
        return json.load(response)["message"]["content"]


def parse(reply, count):
    """`1=Mirza` per line, loosely. Missing answers come back as None."""
    got = [None] * count
    for match in re.finditer(r"(\d+)\s*[=:.]\s*([^\n|,]+)", reply):
        index = int(match.group(1)) - 1
        if 0 <= index < count:
            got[index] = match.group(2).strip().strip('".')
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("cases")
    ap.add_argument("--glossary", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    cases = json.loads(pathlib.Path(args.cases).read_text())
    glossary = GLOSSARY if args.glossary else {}

    # The answer for a slot is the heard word unless this pair is one of the
    # corrections hand-checked on the archive sweep.
    RIGHT = {
        ("Versailles", "Vercel"), ("Versailles.", "Vercel"), ("Myrza", "Mirza"),
        ("Precy", "Praisy"), ("RXV", "Arexvy"), ("RX V", "Arexvy"),
        ("on olma.", "Ollama"), ("praised.", "Praisy"),
    }
    keep_ok = keep_total = change_ok = change_total = 0
    elapsed, wrong = 0.0, []

    for case in cases:
        slots = case["slots"]
        user = slot_prompt(case, glossary)
        started = time.time()
        try:
            reply = ask(args.model, SYSTEM, user, len(slots))
        except Exception as error:
            reply = f"(failed: {error})"
        elapsed += time.time() - started
        got = parse(reply, len(slots))

        for slot, answer in zip(slots, got):
            heard = slot["heard"]
            term = next((t for t in slot["candidates"] if (heard, t) in RIGHT), None)
            want = term or heard
            ok = (answer or "").lower().strip() == want.lower()
            if term:
                change_total += 1; change_ok += ok
            else:
                keep_total += 1; keep_ok += ok
            if not ok:
                wrong.append((heard, want, answer, case["said"][:70]))
            if args.verbose:
                print(f"  {'ok  ' if ok else 'FAIL'} {heard!r} -> want {want!r},"
                      f" got {answer!r}")

    total = keep_total + change_total
    print(f"\n{args.model}{' +glossary' if args.glossary else ''}"
          f"  ({len(cases)} sentences, {total} slots)")
    print(f"  keep the word   {keep_ok}/{keep_total}"
          f"  {keep_ok / max(keep_total, 1) * 100:.0f}%")
    print(f"  use the name    {change_ok}/{change_total}"
          f"  {change_ok / max(change_total, 1) * 100:.0f}%")
    print(f"  overall         {keep_ok + change_ok}/{total}"
          f"  {(keep_ok + change_ok) / max(total, 1) * 100:.0f}%"
          f"   {elapsed / max(len(cases), 1):.2f}s per sentence")

    if wrong and not args.verbose:
        print(f"\n  wrong ({len(wrong)}):")
        for heard, want, answer, said in wrong[:14]:
            print(f"    {heard!r} want {want!r}, got {answer!r}")
            print(f"      {said}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
