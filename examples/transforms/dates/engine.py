"""Writing a dictated date, minus the language. Imported by `en.py` and `fr.py`.

A dictated date already carries its format: "le dix du douze" is 10/12,
"March third" is March 3. No language file is told a target format, and none
reads a calendar: no "next Tuesday", no year invented for a bare date.

A language file exposes `RULES`, an ordered list of (name, compiled regex,
handler). A handler is `f(match, text) -> str | None`: what to write in place
of the match, or None to leave it alone. Order is the whole of rule precedence.
`rewrite` applies each rule over the text left to right, taking non-overlapping
matches, and a rule never sees another rule's output.

The number words come from `examples/transforms/numbers/<code>.py`, so the two
transforms cannot drift. A dates file adds month names, cue words, and the
ordinals the numbers grammar leaves out.

Adding a language: write `numbers/<code>.py` first, copy `fr.py`, edit its
words, patterns, handlers and `RULES`, write `cases-<code>.yaml` beside it, and
add a `transforms:` entry and a step above the numbers step.
"""
import importlib.util
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

# Off with `--no-wall-clock` on the `command:` line. A language file that
# resolves a spoken hour against the clock has to consult it.
WALL_CLOCK = True


def alt(words):
    """An alternation, longest first — "quatorze" must beat "quatre"."""
    return "|".join(re.escape(w) for w in sorted(words, key=lambda w: (-len(w), w)))


def split(text):
    """The words of a fragment, lowercased, hyphen and space treated alike."""
    return re.sub(r"[-\u2011\s]+", " ", (text or "").strip().lower()).split()


WORD_BEFORE = re.compile(r"([\w'\u2019-]+)\s*$")


def word_after(text, at):
    """The next word after offset `at`, lowercased, or "" at the end."""
    found = re.match(r"\s*([\w'\u2019-]+)", text[at:])
    return found.group(1).lower() if found else ""


def word_before(text, at):
    """The word ending at offset `at`, lowercased, or ""."""
    found = WORD_BEFORE.search(text[:at])
    return found.group(1).lower() if found else ""


def now():
    """The clock the wall-clock rule reads.

    `PARROTFLOW_NOW` is an ISO local time and overrides it, which is how the
    case sets pin an answer. A value that will not parse is ignored.
    """
    stamp = os.environ.get("PARROTFLOW_NOW")
    if stamp:
        try:
            return datetime.fromisoformat(stamp)
        except ValueError:
            pass
    return datetime.now()


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def numbers_grammar(code):
    """The `Grammar` the numbers transform reads `code` with."""
    folder = Path(__file__).resolve().parents[1] / "numbers"
    script = folder / f"{code}.py"
    if not script.exists():
        sys.exit(f"dates: {script} is missing. The numbers transform holds the"
                 " word tables and its folder has to sit beside this one.")
    # `numbers/<code>.py` says `import engine` and means its own, not this one.
    # Swapped in for the load and put back after.
    ours = sys.modules.get("engine")
    sys.modules["engine"] = load("numbers_engine", folder / "engine.py")
    try:
        return load(f"numbers_{code}", script).GRAMMAR
    finally:
        if ours is None:
            del sys.modules["engine"]
        else:
            sys.modules["engine"] = ours


class Words:
    """The number words a date is made of, taken from the numbers transform.

    `ordinals` adds the ordinals the numbers grammar leaves out on purpose.
    `zeros` adds a spelling of nought that is not a number word on its own.
    """

    def __init__(self, code, ordinals=None, zeros=()):
        g = numbers_grammar(code)
        self.code = code
        self.units = {word: value for word, value in g.units.items() if value}
        self.ones = {**g.units, **g.teens}
        self.ones.update({word: 0 for word, role in g.connectors.items()
                          if role == "oh"})
        self.tens = dict(g.tens)
        self.ordinals = {**g.ordinal_units, **g.ordinal_teens,
                         **(ordinals or {})}
        self.ordinal_tens = dict(g.ordinal_tens)
        self.joiners = {word for word, role in g.connectors.items()
                        if role == "and"}
        self.zeros = {word for word, value in self.ones.items()
                      if value == 0} | set(zeros)
        self.thousands = {word for word, value in g.scales.items()
                          if value == 1000}
        self.suffixes = {g.ordinal_suffix(value) for value in range(1, 32)}

    def number(self, text):
        """0-99 from words or digits, or None."""
        parts = split(text)
        if len(parts) == 1:
            if parts[0].isdigit():
                return int(parts[0])
            return self.ones.get(parts[0], self.tens.get(parts[0]))
        # "vingt et un".
        if (len(parts) == 3 and parts[0] in self.tens
                and parts[1] in self.joiners):
            if self.units.get(parts[2]) != 1:
                return None
            return self.tens[parts[0]] + 1
        if len(parts) != 2:
            return None
        first, last = parts
        unit = self.units.get(last)
        if unit is None:
            return None
        if first in self.tens:
            return self.tens[first] + unit
        if first in self.zeros:
            return unit
        # "dix-sept", where the teens table stops below it.
        if self.ones.get(first) == 10 and 10 + unit not in self.ones.values():
            return 10 + unit
        return None

    def ordinal(self, text):
        """1-99 from an ordinal, word or "3rd", or None."""
        parts = split(text)
        digits = re.fullmatch(rf"(\d{{1,2}})(?:{alt(self.suffixes)})",
                              " ".join(parts))
        if digits:
            return int(digits.group(1))
        if len(parts) == 1:
            return self.ordinals.get(parts[0],
                                     self.ordinal_tens.get(parts[0]))
        if len(parts) == 2 and parts[0] in self.tens:
            unit = self.ordinals.get(parts[1])
            return self.tens[parts[0]] + unit if unit and unit <= 9 else None
        return None

    def year(self, text):
        """1000-2999 from a spoken year, or None."""
        parts = split(text)
        if len(parts) == 1 and parts[0].isdigit():
            value = int(parts[0])
            return value if 1000 <= value <= 2999 else None
        if len(parts) < 2:
            return None
        # "two thousand and five", "deux mille cinq".
        if parts[1] in self.thousands:
            lead = self.units.get(parts[0])
            if lead is None or lead > 2:
                return None
            rest = parts[2:]
            if rest and rest[0] in self.joiners:
                rest = rest[1:]
            if not rest:
                return lead * 1000
            value = self.number(" ".join(rest))
            return lead * 1000 + value if value is not None else None
        # "nineteen eighty-four", "twenty twenty-six".
        century = self.ones.get(parts[0], self.tens.get(parts[0]))
        if century is None or not 10 <= century <= 29:
            return None
        value = self.number(" ".join(parts[1:]))
        return century * 100 + value if value is not None else None


def apply_rule(text, name, pattern, handler, applied):
    """Every non-overlapping match the handler accepts, left to right."""
    out, at = [], 0
    for m in pattern.finditer(text):
        if m.start() < at:
            continue
        written = handler(m, text)
        if written is None or written == m.group(0):
            continue
        out.append(text[at:m.start()])
        out.append(written)
        at = m.end()
        applied.append(name)
    out.append(text[at:])
    return "".join(out)


def rewrite(text, rules, applied=None):
    """The dates and times in `text`, written as they were spoken."""
    applied = [] if applied is None else applied
    for name, pattern, handler in rules:
        text = apply_rule(text, name, pattern, handler, applied)
    return text


def main(module):
    """The entry point every language file ends with."""
    global WALL_CLOCK
    if "--no-wall-clock" in sys.argv[1:]:
        WALL_CLOCK = False

    # ParrotFlow sets PARROTFLOW_PROTOCOL=json when the transform declares
    # `returns: json`, and then stdin is the envelope. Unset is the plain path,
    # which is what a bare `echo … | en.py` gets.
    structured = os.environ.get("PARROTFLOW_PROTOCOL") == "json"
    raw = sys.stdin.read()
    envelope = json.loads(raw) if structured else {"text": raw}
    text = envelope["text"]

    applied = []
    try:
        out = rewrite(text, module.RULES, applied)
    except Exception:
        # Fail open — never drop the whole transcript because a guard threw.
        out = text
        applied.clear()

    if not structured:
        sys.stdout.write(out)
        return
    print(json.dumps({
        "text": out,
        # Deduplicated: two times in one sentence name the rule once.
        "vars": {"count": len(applied),
                 "applied": ", ".join(dict.fromkeys(applied)),
                 "language": (envelope.get("ctx") or {}).get("language") or ""},
    }))
