#!/usr/bin/env python3
"""Score the *shipped* judge question in two shapes, against the cached menus.

    scripts/judge-blanks.py                    # both arms, one table
    scripts/judge-blanks.py --show 10-12-37    # the two prompts for one clip, verbatim
    scripts/judge-blanks.py --repeat 3         # run both arms three times over
    scripts/judge-blanks.py --order sorted     # letter the blanks' candidates differently
    scripts/judge-blanks.py --json out.json    # per-case results
    scripts/judge-blanks.py --dump-failures tests/judge-failures.txt

Round 1 (`judge-framings.py`) changed the judge's question and found that no
wording wins (F17). Round 2 (`judge-routing.py`) tried to route each case away
from the judge, found the router inverted, and found one thing that did move:
the same question asked per blank instead of per sentence takes the
ordinary-word collision class from 3/8 to 6/8. But round 2 changed the wording
*and* the shape at once, so it cannot say which one did it.

This file changes one thing. Both arms carry the shipped `verify_names.md`, the
same vocabulary list and the same score block. Only the shape differs:

    sentence   every reading of the whole sentence, lettered — what ships today
    blank      the sentence once with each uncertain span blanked and numbered,
               the candidates listed under each number, answered `1=A 2=B`

Three sentences of the shipped prompt have to change, because they describe the
shape of the answer. They are quoted in `BLANK_EDITS` and the run fails loudly
if one stops matching the prompt file. Nothing else moves.

Two numbers are printed for each arm and both are needed. The **case** total is
what every earlier round reported, and it is all-or-nothing: a three-span case
scores zero whether it missed one span or three. The **span** tally splits the
errors into the two that are not the same mistake — a name written over an
ordinary word, and a name lost — because the decision between these shapes is a
decision about which of those to prefer.

`--order` is the control on the one free choice a blank forces: which candidate
gets the letter A. It changes no word of the question, and it moves the blank
arm more than the shape does. The sentence arm ignores it, which is the check
that only the stated variable moves.

**The same 53 cases are tuned on and reported on.** There is no held-out set,
and every number here excludes the 15 live collisions PR #70 added to
`tests/menu-cases.yaml` — the menu cache predates them and re-harvesting needs
the app built.
"""
import argparse
import json
import os
import re
import string
import sys
import urllib.request
from math import prod
from pathlib import Path
from importlib.machinery import SourceFileLoader

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "tests/judge-menus.json"
PROMPT = ROOT / "examples/prompts/verify_names.md"
ENDPOINT = os.environ.get("PARROTFLOW_LLM_ENDPOINT", "http://localhost:11434") + "/api/chat"

recall = SourceFileLoader("recall", str(ROOT / "scripts/menu-recall.py")).load_module()
tune = SourceFileLoader("tune", str(ROOT / "scripts/tune-judge.py")).load_module()
framings = SourceFileLoader("framings", str(ROOT / "scripts/judge-framings.py")).load_module()
# The slot recovery — `slots`, `check`, `analyse` — is round 2's and is not
# rebuilt here. It diffs the menu options against each other to find the spans
# the spotter was unsure about, and refuses to run on a case whose slots do not
# rebuild the menu exactly.
routing = SourceFileLoader("routing", str(ROOT / "scripts/judge-routing.py")).load_module()

COLLISIONS = framings.COLLISIONS


# ── the one difference between the arms ──────────────────────────────────────
# Exact substrings of the shipped prompt, replaced in order. Only sentences
# that describe the *shape* of the question and of the answer are touched. The
# vocabulary list, the paragraph about "spells", the paragraph about the
# acoustic gap and the "makes sense as a sentence" test are all left as they
# ship — those are the content, and round 2 already showed content moves more
# than shape does.

BLANK_EDITS = [
    ("A name matcher was unsure about some words. Below is the sentence, and every\n"
     "reading it might really have been. Exactly one is what the user said.",
     "A name matcher was unsure about some words. Below is the sentence with each of\n"
     "them blanked and numbered, and every reading each blank might really have been.\n"
     "Exactly one reading of each blank is what the user said."),

    ("Pick the reading that makes sense as a sentence, unless the sound says\n"
     "otherwise by more than about 4. Answer with its letter only.",
     "Pick the reading of each blank that makes sense as a sentence, unless the sound\n"
     "says otherwise by more than about 4. Answer with one letter per blank and\n"
     'nothing else, like "1=A 2=B".'),
]

# The user message ends with this in the blank arm. The sentence arm ends with
# the app's own "Which letter?", which `tune.ask` appends. One string is used
# whatever the slot count, so a single-blank case and a three-blank case are
# asked in exactly the same words — otherwise the multi-slot split below would
# be comparing two different prompts.
BLANK_TAIL = "\n\nWhich letter for each blank?"


def blank_prompt():
    """The shipped prompt with the three shape sentences replaced.

    Every edit must match exactly once. A silently missing edit would turn this
    arm back into the control and report it as a finding, which is the one
    failure this harness cannot be allowed to have. `framings.build` guards its
    own edits the same way and for the same reason.
    """
    text = PROMPT.read_text().strip()
    for old, new in BLANK_EDITS:
        if text.count(old) != 1:
            raise SystemExit(
                f"✗ the blank arm's edit no longer matches {PROMPT.name} exactly once "
                f"({text.count(old)} times).\n   looked for: {old[:60]!r}...")
        text = text.replace(old, new)
    return text


# ── the blank form ───────────────────────────────────────────────────────────

def numbered(ref, spans):
    """The sentence with every uncertain span replaced by `___1___`, `___2___`.

    `routing.blank` blanks one span and leaves the others as the decoder wrote
    them, because round 2 asked one question per span. Here one question covers
    every span, so every span is a hole. That is the whole of the shape change:
    the sentence is stated once, not once per reading.
    """
    out, cursor = [], 0
    for index, (a, b) in enumerate(spans):
        out += ref[cursor:a]
        out.append(f"___{index + 1}___")
        cursor = b
    out += ref[cursor:]
    return " ".join(out)


def slot_options(item, index):
    """A slot's readings, in the order the menu introduces them.

    `routing.analyse` sorts them, which is fine when each slot is its own call.
    Here the letters sit inside the one question the control also answers, and
    letter order is a real effect on a small model — so the order is taken from
    the menu the app itself built. Then the only thing that differs between the
    two arms is the shape. `--order sorted` measures what that choice is worth.
    """
    seen = []
    for fillers in item["fillers"]:
        if fillers[index] not in seen:
            seen.append(fillers[index])
    return seen


def options_for(item, order):
    per_slot = [slot_options(item, i) for i in range(len(item["spans"]))]
    if order == "sorted":
        per_slot = [sorted(o) for o in per_slot]
    # The cartesian product of the slot readings has to be the menu, or the two
    # arms are not answering the same question and chance is not the same
    # number. `routing.check` already proved the two *sets* are equal; this
    # proves no menu option is a duplicate of another, which is what makes the
    # sizes agree too.
    if prod(len(o) for o in per_slot) != len(item["case"]["menu"]):
        raise SystemExit(
            f'✗ {routing.stamp(item["case"])}: {len(item["case"]["menu"])} options but '
            f'{prod(len(o) for o in per_slot)} combinations of slot readings')
    return per_slot


def question(item, order):
    """The user message of the blank arm, score block and all."""
    lines = [numbered(item["ref"], item["spans"]), ""]
    for index, options in enumerate(options_for(item, order)):
        for letter, option in enumerate(options):
            head = f"{index + 1}." if letter == 0 else "  "
            lines.append(f"{head} {string.ascii_uppercase[letter]}. {option}")
        lines.append("")
    # The score block goes in exactly as the app wrote it and exactly as the
    # control receives it. It names spellings, not slots, so it needs no
    # rewriting for the blanks — and rewriting it would be a second variable.
    return "\n".join(lines).rstrip() + (item["case"].get("scores") or "") + BLANK_TAIL


ANSWER = re.compile(r"(\d+)\s*[=:.\)]?\s*([A-Za-z])\b")
STRAY = []        # replies this harness could not map onto the blanks at all


def read_answer(reply, per_slot):
    """(the reading each blank was given, how the reply was read).

    `1=A 2=B` is what the prompt asks for and it is not what most replies give.
    Two fallbacks are allowed, and which one was used is recorded per case
    rather than assumed, because a shape whose answers cannot be read is a
    worse shape and hiding that would flatter the arm.

    * `numbered`   — the asked-for form.
    * `letters`    — one bare letter per blank, in order. `A B` for two blanks.
    * `app rule`   — a single blank answered with a single letter, read by
                     `tune.chosen`, which is the app's own rule and is exactly
                     what the control does with the same reply.
    * `unreadable` — nothing this harness can map onto the blanks. Counted as
                     wrong, and collected in STRAY.
    """
    picked = {}
    for number, letter in ANSWER.findall(reply):
        index = int(number) - 1
        letter = string.ascii_uppercase.index(letter.upper())
        if 0 <= index < len(per_slot) and letter < len(per_slot[index]):
            picked.setdefault(index, per_slot[index][letter])
    if len(picked) == len(per_slot):
        return [picked[i] for i in range(len(per_slot))], "numbered"

    if len(per_slot) == 1:
        index = tune.chosen(reply, len(per_slot[0]))
        if index is None:
            STRAY.append(reply)
            return None, "unreadable"
        return [per_slot[0][index]], "app rule"

    bare = [w for w in re.split(r"[^A-Za-z]+", reply.upper())
            if len(w) == 1 and w in string.ascii_uppercase]
    if len(bare) == len(per_slot):
        out = []
        for options, letter in zip(per_slot, bare):
            index = string.ascii_uppercase.index(letter)
            if index >= len(options):
                STRAY.append(reply)
                return None, "unreadable"
            out.append(options[index])
        return out, "letters"
    STRAY.append(reply)
    return None, "unreadable"


def ask_blanks(model, system, item, order):
    """One call per case, like the control. The answer names every blank.

    `num_predict` is the app's 8 for a single blank and grows with the blanks,
    because `1=A 2=B 3=C` is simply a longer answer than `B`. That is a
    consequence of the shape, not a second variable — the control cannot spend
    those tokens on anything, since it answers one letter.
    """
    per_slot = options_for(item, order)
    user = question(item, order)
    payload = {
        "model": model, "stream": False, "think": False,
        "options": {"temperature": 0, "num_predict": max(8, 6 * len(per_slot))},
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user}],
    }
    request = urllib.request.Request(
        ENDPOINT, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=120) as response:
        reply = json.loads(response.read())["message"]["content"].strip()
    tune.LAST.clear()
    tune.LAST.update(system=system, user=user, reply=reply)
    picked, item["how"] = read_answer(reply, per_slot)
    return picked


def ask_sentence(model, system, item):
    """The control — the app's own call, on the app's own whole-sentence menu."""
    case = item["case"]
    chosen = tune.ask(model, system, case["menu"], case.get("scores") or "")
    if chosen is None:
        return None
    return item["fillers"][case["menu"].index(chosen)]


ARMS = {
    "sentence": "the shipped prompt, whole-sentence menu — what ships today",
    "blank": "the shipped prompt, one numbered blank per uncertain span",
}


def run(items, arm, model, order):
    system = (framings.build("baseline") if arm == "sentence" else blank_prompt())
    for item in items:
        case = item["case"]
        if arm == "sentence":
            got = ask_sentence(model, system.replace("{terms}", case["terms"]), item)
        else:
            got = ask_blanks(model, system.replace("{terms}", case["terms"]), item, order)
        item[arm] = got == item["truth"]
        item[arm + " chose"] = got
        # Kept so `--dump-failures` can print the call rather than rebuild it.
        item[arm + " call"] = dict(tune.LAST)


def trade(items, arm):
    """Per span, the two ways an arm can be wrong. Counting cases hides this.

    A case is right only when every span is, so a three-span case scores zero
    whether it missed one span or three. The two errors are not the same error
    and the decision between the arms is a decision about which one to prefer:

        overwrite   the speaker said the ordinary word, the arm wrote the name.
                    This is the class the whole spike exists for (F17).
        name lost   the speaker said the name, the arm kept what was decoded.

    The decoded reading of a span is `routing.decoded_filler` — the one reading
    carrying no vocabulary term, which is exact because the proposals are the
    only thing that put those spellings on the menu.
    """
    right = overwrite = lost = spans = 0
    for item in items:
        chose = item.get(arm + " chose")
        for index, truth in enumerate(item["truth"]):
            spans += 1
            got = chose[index] if chose else None
            if got == truth:
                right += 1
            elif truth == item["heard"][index]:
                overwrite += 1
            else:
                lost += 1
    return right, overwrite, lost, spans


RULE = "=" * 78
BAR = "-" * 78


def errors(item, arm):
    """[(kind, what)] — one entry per span this arm got wrong.

    The same rule `trade` counts by. A reply the harness could not read at all
    is its own kind: the arm answered, but not about these blanks.
    """
    chose = item[arm + " chose"]
    if chose is None:
        return [("unreadable", "the reply named no set of blanks")]
    out = []
    for index, truth in enumerate(item["truth"]):
        if chose[index] != truth:
            kind = "overwrite" if truth == item["heard"][index] else "name lost"
            out.append((kind, f"{truth!r} -> {chose[index]!r}"))
    return out or [("other", "every span is right but the case is not")]


def dump_failures(items, path, model, order, chance):
    """Every failing case in both arms, exactly as the model was given it.

    The messages are the strings that went over the wire, kept by `tune.LAST`
    rather than rebuilt here. A dump that reassembles the prompt is a dump that
    can disagree with the run it claims to explain.
    """
    failed = {arm: [i for i in items if not i[arm]] for arm in ARMS}
    both = {routing.stamp(i["case"]) for i in failed["sentence"]} \
        & {routing.stamp(i["case"]) for i in failed["blank"]}

    out = ["Every judge failure, verbatim — round 3 of the judge spike.", "",
           "What the model was sent and what it said back, for every case each arm",
           "got wrong. Nothing here is tidied, shortened or paraphrased. The system",
           "and user messages are the strings that went over the wire.", "",
           "Regenerate — it must never drift from the numbers in the report:", "",
           f"    scripts/judge-blanks.py --dump-failures {path}", "",
           "The report is docs/proposals/judge-framings.md, round 3.", "",
           f"Judge {model}, temperature 0, letters inside a blank in {order} order.",
           f"{len(items)} reachable cached menus, chance {chance:.1f}.",
           f"sentence {sum(i['sentence'] for i in items)}/{len(items)},"
           f" blank {sum(i['blank'] for i in items)}/{len(items)}.", "",
           "Two errors are named. `overwrite` is a name written where the speaker",
           "said an ordinary word — the failure this whole spike is about. `name",
           "lost` is a real name left as the decoder mangled it. A span that `slots`",
           "merged can hold both, and then it is named by whichever the whole span",
           "matches.", "", RULE, "INDEX", RULE, ""]

    for arm in ARMS:
        out += [f"{arm} arm — {len(failed[arm])} failures", ""]
        for item in failed[arm]:
            stamp = routing.stamp(item["case"])
            kinds = ", ".join(sorted({kind for kind, _ in errors(item, arm)}))
            mark = "both arms fail" if stamp in both else ""
            out.append(f"  {stamp:<10} {len(item['spans'])} span(s)  "
                       f"{kinds:<24} {mark}")
        out.append("")

    for arm in ARMS:
        out += [RULE, f"{arm.upper()} ARM — {len(failed[arm])} FAILURES", RULE, ""]
        for item in failed[arm]:
            stamp = routing.stamp(item["case"])
            call = item[arm + " call"]
            out += [BAR,
                    f"clip      {stamp}",
                    f"arm       {arm}",
                    f"both      {'yes — the other arm fails this clip too' if stamp in both else 'no — the other arm gets this clip'}",
                    f"spans     {len(item['spans'])}",
                    f"said:     {item['case']['said']}",
                    f"true:     {item['truth']}"]
            out += [f"error:    {kind:<11} {what}" for kind, what in errors(item, arm)]
            out += ["", "--- system message ---", call["system"],
                    "--- user message ---", call["user"],
                    "--- reply ---", call["reply"],
                    "--- resolved to ---", repr(item[arm + " chose"]), ""]
        out.append(BAR)
        out.append("")

    Path(path).write_text("\n".join(out))
    return failed, both


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.environ.get("PARROTFLOW_JUDGE_MODEL", "gemma4:e4b"))
    ap.add_argument("--order", default="menu", choices=["menu", "sorted"],
                    help="letter order inside a blank (default: the menu's own)")
    ap.add_argument("--repeat", type=int, default=1,
                    help="run both arms this many times, to show the totals are stable")
    ap.add_argument("--show", metavar="STAMP",
                    help="print both prompts for one clip, verbatim, and stop")
    ap.add_argument("--json", metavar="PATH", help="write per-case results here")
    ap.add_argument("--dump-failures", metavar="PATH",
                    help="write every failing case of both arms, verbatim, here")
    args = ap.parse_args()

    if not CACHE.exists():
        print("✗ no cache — run scripts/tune-judge.py --harvest first")
        return 2
    cases, unreachable = routing.reachable(json.loads(CACHE.read_text()))
    items = routing.analyse(cases)

    if args.show:
        item = next((i for i in items if routing.stamp(i["case"]) == args.show), None)
        if item is None:
            print(f"✗ no reachable case {args.show!r}")
            return 2
        case = item["case"]
        print(f'\n  said   {case["said"]}\n  terms  {case["terms"]}')
        print("\n─── arm 1, sentence — SYSTEM ───\n")
        print(framings.build("baseline").replace("{terms}", case["terms"]))
        print("\n─── arm 1, sentence — USER ───\n")
        # Mirrors the message `tune.ask` builds. It is printed rather than
        # returned by that function, so this is the one place the two can
        # drift; the report quotes it, so check it against `tune.ask` if the
        # app's message changes.
        print("\n".join(f"{string.ascii_uppercase[i]}. {o}"
                        for i, o in enumerate(case["menu"]))
              + (case.get("scores") or "") + "\n\nWhich letter?")
        print("\n─── arm 2, blank — SYSTEM ───\n")
        print(blank_prompt().replace("{terms}", case["terms"]))
        print("\n─── arm 2, blank — USER ───\n")
        print(question(item, args.order))
        return 0

    # Chance is the same number for both arms, and that is not a coincidence:
    # the slot readings multiply out to the menu, so guessing a letter per
    # blank and guessing a letter on the menu are the same lottery.
    chance = sum(1 / len(c["menu"]) for c in cases)
    multi = [i for i in items if len(i["spans"]) > 1]
    single = [i for i in items if len(i["spans"]) == 1]
    slots = sum(len(i["spans"]) for i in items)

    print(f"\n  {len(cases)} reachable menus, {unreachable} never held the answer."
          f"  Judge {args.model}, temperature 0.")
    print(f"  Chance is {chance:.1f}/{len(cases)}, the same for both arms (F13).")
    print(f"  {len(multi)} cases hold more than one uncertain span "
          f"({sum(len(i['spans']) for i in multi)} spans), "
          f"{len(single)} hold one. {slots} spans over the {len(cases)} cases.")
    print(f"  Letters inside a blank are in {args.order} order.")
    print(f"  The same {len(cases)} cases are tuned on and reported on."
          " There is no held-out set.")
    print("  The cache predates PR #70, so none of the 15 live collisions"
          " of 2026-08-08 are in it.\n")

    for pass_number in range(args.repeat):
        before = len(STRAY) + len(tune.STRAY)
        for arm in ARMS:
            run(items, arm, args.model, args.order)
        if args.repeat > 1:
            print(f"  run {pass_number + 1}   "
                  + "   ".join(f"{a} {sum(i[a] for i in items)}/{len(cases)}"
                               for a in ARMS)
                  + f"   ({len(STRAY) + len(tune.STRAY) - before} unreadable replies)")
    if args.repeat > 1:
        print()

    # How the blank arm's replies came back, over the last run only. The asked
    # -for `1=A 2=B` is the minority; the rest is bare letters, which the app's
    # own rule reads. None of it is a reason a case was scored wrong.
    last = {how: sum(i.get("how") == how for i in items)
            for how in ("numbered", "letters", "app rule", "unreadable")}
    print("  blank-arm replies — "
          + ", ".join(f"{count} {how}" for how, count in last.items() if count))

    print(f"  {'arm':<10}{'total':<12}{'multi-slot':<14}{'single-slot':<14}"
          f"{'collision':<12}")
    at = {routing.stamp(i["case"]): i for i in items}
    scored = [at[c] for c in COLLISIONS if c in at]
    for arm, doc in ARMS.items():
        print(f"  {arm:<10}"
              f"{f'{sum(i[arm] for i in items)}/{len(cases)}':<12}"
              f"{f'{sum(i[arm] for i in multi)}/{len(multi)}':<14}"
              f"{f'{sum(i[arm] for i in single)}/{len(single)}':<14}"
              f"{f'{sum(i[arm] for i in scored)}/{len(scored)}':<12}{doc}")
    print(f"  {'chance':<10}{chance:<12.1f}"
          f"{sum(1 / len(i['case']['menu']) for i in multi):<14.1f}"
          f"{sum(1 / len(i['case']['menu']) for i in single):<14.1f}"
          f"{sum(1 / len(i['case']['menu']) for i in scored):<12.1f}")

    print(f"\n  by span, not by case — {slots} spans, and the two ways to be wrong\n")
    print(f"  {'arm':<10}{'right':<12}{'wrote the name over an':<26}"
          f"{'kept what was decoded,':<26}")
    print(f"  {'':<10}{'':<12}{'ordinary word':<26}{'losing the name':<26}")
    for arm in ARMS:
        right, overwrite, lost, spans_seen = trade(items, arm)
        print(f"  {arm:<10}{f'{right}/{spans_seen}':<12}{overwrite:<26}{lost:<26}")
    print("\n  A case counts only when every one of its spans is right, so the totals"
          "\n  above hide this. The two columns are the trade between the arms.")

    print(f"\n  the collision class, by span — {sum(len(at[c]['spans']) for c in COLLISIONS if c in at)}"
          " spans over the 8 reachable clips\n")
    for arm in ARMS:
        right, overwrite, lost, spans_seen = trade(scored, arm)
        print(f"  {arm:<10}{f'{right}/{spans_seen}':<12}{overwrite:<26}{lost:<26}")

    if STRAY or tune.STRAY:
        print(f"\n  {len(tune.STRAY)} sentence-arm replies had no bare letter;"
              f" {len(STRAY)} blank-arm replies could not be read at all.")
        for reply in (STRAY + tune.STRAY)[:4]:
            print(f"    {reply!r}")

    print("\n  per case — + the blank arm won, - it lost\n")
    for name, subset in (("all", items), ("multi-slot", multi), ("single-slot", single)):
        won = [routing.stamp(i["case"]) for i in subset if i["blank"] and not i["sentence"]]
        lost = [routing.stamp(i["case"]) for i in subset if i["sentence"] and not i["blank"]]
        print(f"  {name:<12} +{len(won)} {' '.join(won) or '-'}")
        print(f"  {'':<12} -{len(lost)} {' '.join(lost) or '-'}")

    print(f"\n  the ordinary-word collision class — {len(COLLISIONS)} clips, PR #68\n")
    print("  " + f"{'clip':<10}{'slots':<7}{'what collided':<44}"
          + "".join(f"{a:<10}" for a in ARMS))
    for clip, what in COLLISIONS.items():
        item = at.get(clip)
        if item is None:
            print(f"  {clip:<10}{'':<7}{what:<44}unreachable — never on the menu")
            continue
        marks = "".join(f"{'✓' if item[a] else '✗':<10}" for a in ARMS)
        print(f"  {clip:<10}{len(item['spans']):<7}{what:<44}{marks}")
    print("  " + f"{'total':<10}{'':<7}{'':<44}"
          + "".join(f"{f'{sum(i[a] for i in scored)}/{len(scored)}':<10}" for a in ARMS))

    if args.dump_failures:
        failed, both = dump_failures(items, args.dump_failures, args.model,
                                     args.order, chance)
        print(f"\n  {len(failed['sentence'])} sentence-arm failures,"
              f" {len(failed['blank'])} blank-arm failures,"
              f" {len(both)} clips both arms fail")
        print(f"  written verbatim to {args.dump_failures}")

    if args.json:
        Path(args.json).write_text(json.dumps(
            [{"wav": i["case"]["wav"], "said": i["case"]["said"],
              "slots": len(i["spans"]), "options": options_for(i, args.order),
              "decoded": i["heard"], "true": i["truth"], "read as": i.get("how"),
              **{a: i[a] for a in ARMS},
              **{f"{a} chose": i[f"{a} chose"] for a in ARMS}} for i in items],
            indent=1, ensure_ascii=False))
        print(f"\n  per-case results written to {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
