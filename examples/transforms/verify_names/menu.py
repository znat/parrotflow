#!/usr/bin/env python3
"""Judge a whole reading, not one word at a time.

The vocabulary matches on sound and cannot read the sentence, so it replaces
ordinary words that happen to sound like a name. `verify_names.py` asks one
YES/NO per replacement, which is the right shape when there is one, and cannot
express the answer when there are two:

    heard:  Mira and Mirza … deployed on Versailles … the Versailles castle
    meant:  Mira and Mirza … deployed on Vercel     … the Versailles castle

One word, two answers, one sentence. A per-word question is asked about
`Versailles` twice and has no way to answer differently.

So this builds every reading the replacements allow and asks the model to pick
one. The model returns a letter. The letter is looked up here — the model never
writes the transcript, which is what stops it tidying the grammar on the way
past. Measured: a prompt asked to return the corrected sentence mangled 15 of
58 inputs. This shape cannot, because the output is chosen from a list this
script built.

## What is a letter and what is code

The prompt is `menu.md` and holds no logic. Everything below it is mechanical
and would be wrong to ask a model for: which words are uncertain, what the
readings are, and which sentence a letter stands for.

## Cost

`MAX_SLOTS` readings is 2**n, and the model is worse at long lists. Three slots
is eight readings, which is the most that measured usefully. Past that the
extra slots keep the matcher's answer, which is what today ships anyway.
"""
import itertools
import json
import os
import re
import string
import sys
import urllib.request

MODEL = os.environ.get("PARROTFLOW_JUDGE_MODEL", "gemma4:e4b")
ENDPOINT = os.environ.get("PARROTFLOW_LLM_ENDPOINT", "http://localhost:11434") + "/api/chat"
TIMEOUT = float(os.environ.get("PARROTFLOW_JUDGE_TIMEOUT", "20"))

# Uncertain positions, not replacements. One rule can rewrite three words.
MAX_SLOTS = int(os.environ.get("PARROTFLOW_JUDGE_MAX_SLOTS", "4"))

# The menu, not the slot count, is what the model is bad at. Three binary slots
# is eight readings and was the most that measured useful, so eight is the
# number — a slot offering three readings costs another slot's second one.
MAX_READINGS = int(os.environ.get("PARROTFLOW_JUDGE_MAX_READINGS", "16"))

# Readings per slot, the decoder's own included. Two alternatives is what a
# lettered list stays readable at.
MAX_PER_SLOT = int(os.environ.get("PARROTFLOW_JUDGE_MAX_PER_SLOT", "3"))

HERE = os.path.dirname(os.path.abspath(__file__))
PROMPT_FILE = os.environ.get("PARROTFLOW_JUDGE_PROMPT", os.path.join(HERE, "menu.md"))


def prompt_text():
    with open(PROMPT_FILE, encoding="utf-8") as handle:
        return handle.read().strip()


def acoustic_slots(context, text):
    """Undecided words from the acoustic pass, located by what was decoded.

    `Vocabulary.swift` publishes `proposals` with `nth` — which occurrence of
    the *decoded* word this is. That is the whole fix. The pass no longer
    substitutes what it is unsure about, so the word in the text is the one the
    decoder wrote, and the menu is built around it rather than around the term.

    Searching for the term was the old way and it could not tell two proposals
    apart when they shared one. On "Let's praise the work Prissy has done" the
    pass proposed `praise -> Praisy` and `Prissy -> Praisy`; both searches hit
    both positions, sort order handed `Prissy` to each, and the reading the
    speaker said was not on the menu at all.

    `applied: true` entries are not slots. The audio was clear and the word did
    not collide with anything real, so there is nothing to ask.
    """
    stages = (context.get("vars") or {})
    raw = (stages.get("vocabulary") or {}).get("proposals") or "[]"
    try:
        items = json.loads(raw)
    except (ValueError, TypeError):
        return []

    found = []
    for item in items:
        if item.get("applied"):
            continue
        heard, term = item.get("heard") or "", item.get("term") or ""
        if not (heard and term) or heard == term:
            continue
        spans = [m.span() for m in re.finditer(re.escape(heard), text)]
        nth = item.get("nth") or 0
        if nth >= len(spans):
            continue
        start, end = spans[nth]
        # The span holds what the decoder wrote; the term is the alternative.
        found.append((start, end, heard, term, term))
    return found


def score_block(context):
    """How clearly each uncertain word was heard, as words rather than sums.

    The numbers are log-probabilities with the vocabulary bonus already taken
    out by `Vocabulary.apply`, so the two spellings are comparable for the
    first time — the older score block showed the boosted figure, which said
    the term was heard more clearly when often it was not.

    The difference is precomputed. A small model is unreliable at arithmetic on
    negative numbers, and this judge has already measured that asking it for
    more reasoning costs accuracy.
    """
    raw = ((context.get("vars") or {}).get("vocabulary") or {}).get("proposals") or "[]"
    try:
        items = json.loads(raw)
    except (ValueError, TypeError):
        return ""

    lines, seen = [], set()
    for item in items:
        if item.get("applied") or not item.get("term_score"):
            continue
        heard, term = item.get("heard", ""), item.get("term", "")
        key = (heard, term)
        if key in seen or not (heard and term):
            continue
        seen.add(key)
        a, b = float(item["heard_score"]), float(item["term_score"])
        gap = abs(a - b)
        worse = term if b < a else heard
        lines.append(f'  "{heard}" {a:.2f}   "{term}" {b:.2f}'
                     f'   — "{worse}" heard {gap:.1f} less clearly')
    if not lines:
        return ""
    return ("\n\nHow clearly the recogniser heard each spelling over that stretch of\n"
            "audio. Closer to zero is clearer, and the vocabulary's own bonus has been\n"
            "taken out, so the two are comparable.\n\n" + "\n".join(lines))


def rule_slots(context, text):
    """The same, for substitutions a `heard:` rule already made.

    A rule has no position to publish — it fired during the `replacements`
    stage, which rewrites text and reports pairs. So these are still found by
    searching for the term, with the old limitation intact: two rules writing
    one term into one sentence cannot be told apart. That is survivable here
    and was not for the acoustic pass, because a rule fires on an exact
    spelling and so proposes far less often.
    """
    stages = (context.get("vars") or {})
    raw = (stages.get("replacements") or {}).get("changes") or ""
    found = []
    for pair in raw.split(";"):
        if "->" not in pair:
            continue
        heard, _, term = pair.partition("@")[0].partition("->")
        heard, term = heard.strip(), term.strip()
        if not (heard and term) or heard == term:
            continue
        # The other way round from the acoustic pass: a rule already rewrote
        # the text, so the span holds the term and the decoded word is what
        # has to be offered back.
        for match in re.finditer(re.escape(term), text):
            found.append((match.start(), match.end(), heard, heard, term))
    return found


def slots(text, found):
    """Every position still in question, left to right, as one slot each.

    Overlapping spans used to be dropped, earliest wins. That was right when
    they were competing substitutions and wrong now they are readings of the
    same words: `Praisy` decoded as "praise he" arrives as both "praise" and
    "praise he", and dropping one leaves a menu where every option strands a
    word. So they are grouped, and the slot covers the widest of them.

    A slot's readings are its span left alone, then the span with each proposal
    written in. Widest last — that is the speculative one, and `readings` drops
    from the end when the menu gets too long.
    """
    parts = sorted(found)
    grouped = []
    for start, end, decoded, other, term in parts:
        part = (start, end, decoded, other, term)
        if grouped and start < grouped[-1]["end"]:
            grouped[-1]["end"] = max(grouped[-1]["end"], end)
            grouped[-1]["parts"].append(part)
        else:
            grouped.append({"start": start, "end": end, "parts": [part]})

    out = []
    for slot in grouped:
        start, end = slot["start"], slot["end"]
        span = lambda at, to, word: text[start:at] + word + text[to:end]

        # The decoder's own reading goes first, and for a rule that is not the
        # text — the rule already rewrote it. Measured: burying the untouched
        # reading costs eight points, because the model agrees with whatever
        # it is shown first.
        options = [text[start:end]]
        for at, to, decoded, _, _ in slot["parts"]:
            if text[at:to] != decoded:
                options = [span(at, to, decoded)]
                break

        for at, to, _, other, _ in sorted(slot["parts"], key=lambda p: p[1] - p[0]):
            reading = span(at, to, other)
            if reading not in options:
                options.append(reading)
        if text[start:end] not in options:
            options.append(text[start:end])

        # At most `MAX_PER_SLOT` readings, the decoder's first.
        #
        # One term can offer four readings of one place — itself and its
        # possessive, over the word and over the word plus the next — and two
        # such slots is a menu of fifteen. Ranked so the widest span survives:
        # the reading that consumes the stranded word is the one the narrow
        # span cannot express, and a possessive is a guess on top of a guess.
        if len(options) > 1:
            head, rest = options[0], options[1:]
            widths = {}
            for at, to, _, other, _ in slot["parts"]:
                widths.setdefault(span(at, to, other), to - at)
            # Widest first, possessive as the tiebreak. The other way round
            # cost three cases: a wide span and its possessive are the same
            # width, and ranking possessives last dropped `Praisy's` over
            # "praise his" in favour of `Praisy` over "his" — which leaves the
            # stranded word the wide span exists to absorb.
            rest.sort(key=lambda r: (-widths.get(r, 0), r.endswith("'s") or "'s " in r))
            options = [head] + rest[:MAX_PER_SLOT - 1]
            out.append((start, end, options, sorted({p[4] for p in slot["parts"]})))
    return out


def readings(text, kept):
    """Every sentence the slots allow, the untouched one first.

    First is the reading with no replacement applied — what the decoder wrote
    before the vocabulary edited it. That is the answer this stage exists to
    make reachable, and burying it costs declines. Measured on
    `tests/judge-cases.yaml` with gemma4:e4b, the only change being which
    reading sits at A:

        untouched first    approve 69%   decline 74%   overall 72%
        substituted first  approve 94%   decline 52%   overall 64%

    The second row is a model agreeing with whatever it is shown first, which
    reads as confidence and is worth eight points of damage.

    A slot can now offer more than two readings, so the menu is trimmed rather
    than the slot count capped. Speculative readings — the wider spans, which
    sort last — go first, because a menu longer than eight measured worse than
    a menu missing its least likely entry.
    """
    kept = [(start, end, list(options)) for start, end, options, _ in kept]
    while True:
        total = 1
        for _, _, options in kept:
            total *= len(options)
        if total <= MAX_READINGS:
            break
        widest = max(kept, key=lambda slot: len(slot[2]))
        if len(widest[2]) <= 2:
            break
        widest[2].pop()

    out = []
    for combo in itertools.product(*[options for _, _, options in kept]):
        built, at = [], 0
        for (start, end, _), pick in zip(kept, combo):
            built.append(text[at:start])
            built.append(pick)
            at = end
        built.append(text[at:])
        candidate = "".join(built)
        # The combo travels with the sentence. Which slots were undone cannot
        # be recovered from the finished string — one word can fill two slots
        # and go two different ways, which is the case this stage exists for.
        if candidate not in [sentence for sentence, _ in out]:
            out.append((candidate, combo))
    return out


def ask(system, options, scores=""):
    # The menu, on stderr, for a harness that wants to know whether the right
    # sentence was ever on it. Two failures wear the same face in the output —
    # a menu without the true reading and a judge that picked the wrong one —
    # and only the first is worth widening the proposals for.
    # A file rather than stderr: the app reads a transform's output off a pipe
    # of its own, so nothing printed there reaches a terminal.
    dump = os.environ.get("PARROTFLOW_JUDGE_DUMP")
    if dump:
        with open(dump, "a", encoding="utf-8") as handle:
            # The system message too, so a tuner can replay the exchange
            # without re-running the app for every prompt it wants to try.
            handle.write("SYSTEM " + system.replace("\n", "\\n") + "\n")
            for i, option in enumerate(options):
                handle.write(f"MENU {string.ascii_uppercase[i]}. {option}\n")
            if scores:
                handle.write("SCORES " + scores.replace("\n", "\\n") + "\n")
    body = "\n".join(
        f"{string.ascii_uppercase[i]}. {option}" for i, option in enumerate(options)
    )
    payload = {
        "model": MODEL, "stream": False, "think": False,
        "options": {"temperature": 0, "num_predict": 8},
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": body + scores + "\n\nWhich letter?"},
        ],
    }
    request = urllib.request.Request(
        ENDPOINT, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        reply = json.loads(response.read())["message"]["content"].strip()

    # Loosely. A model that answers "B." or "Option B" has decided and
    # formatted it badly, and refusing that is refusing a correct answer.
    letter = re.search(r"[A-Za-z]", reply)
    if not letter:
        return None, reply
    index = string.ascii_uppercase.index(letter.group().upper())
    if index >= len(options):
        return None, reply
    return options[index], reply


def main():
    raw = sys.stdin.read()
    if os.environ.get("PARROTFLOW_PROTOCOL") == "json":
        try:
            payload = json.loads(raw)
            text, context = payload.get("text", ""), payload.get("ctx") or {}
        except json.JSONDecodeError:
            text, context = raw, {}
    else:
        text, context = raw, {}

    kept = slots(text, acoustic_slots(context, text) + rule_slots(context, text))
    if not kept:
        return print(json.dumps({}))

    # Too many uncertain words to enumerate. Keeping the matcher's answer is
    # today's behaviour, so this is a decision not to make things worse, and it
    # is logged rather than silent.
    if len(kept) > MAX_SLOTS:
        return print(json.dumps({
            "vars": {"asked": 0, "skipped": f"{len(kept)} slots > {MAX_SLOTS}"}
        }))

    built = readings(text, kept)
    options = [sentence for sentence, _ in built]
    terms = ", ".join(sorted({t for _, _, _, names in kept for t in names}))
    system = prompt_text().replace("{terms}", terms)

    try:
        chosen, reply = ask(system, options, score_block(context))
    except Exception as problem:                       # noqa: BLE001
        # Fail closed: the matcher's answer is what ships today, and a judge
        # that cannot reach its model must not also lose the substitution.
        return print(json.dumps({"vars": {"asked": len(options), "error": str(problem)}}))

    if chosen is None:
        return print(json.dumps({"vars": {"asked": len(options), "reply": reply}}))

    combo = next(c for sentence, c in built if sentence == chosen)
    out = {"vars": {
        "asked": len(options),
        "slots": len(kept),
        # What the judge left alone, in the words it left. "Reverted" was the
        # word for this when the pass substituted first; it proposes now, so a
        # slot that keeps its first reading was never changed to begin with.
        "kept_as_decoded": "; ".join(
            pick for (_, _, options, _), pick in zip(kept, combo) if pick == options[0]
        ),
        "judged": json.dumps(
            [{"options": options, "reply": reply, "chose": chosen}], ensure_ascii=False
        ),
    }}
    if chosen != text:
        out["text"] = chosen
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
