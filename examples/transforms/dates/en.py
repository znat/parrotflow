#!/usr/bin/env python3
"""English dates and clock times, written the way they were said. Transcript on
stdin, rewrite on stdout.

    - name: dates_en
      description: dictated dates and clock times as digits
      command: examples/dates/en.py
      returns: json
      tests: examples/dates/cases-en.yaml

    pipeline:
      - transform: dates_en
        when: <the regex printed by `en.py --when`>

"at ten fifteen" -> "at 10:15". "March third twenty twenty-six" -> "March 3,
2026". "the tenth of the twelfth" -> "10/12". Publishes `count`, how many spans
were rewritten, and `applied`, the rules that fired.

Self-contained. The word tables below are this file's, and `engine.py` beside
it holds only the loop, the JSON protocol and the `--when` printer. See its
docstring for the contract and for how to add a language.

**Before `numbers`, on words.** Measured on the numbers stage: "three thirty",
"at ten fifteen", "half past two" and "March third" all come back unchanged
from it, and "à dix heures quinze" comes back as "à 10 heures 15". Once numbers
has run the words a date is made of are gone. So this reads them first — and it
also accepts digits, because the decoder emits them either way ("March 3rd
2026", "at 10 15").

**No cue, no rewrite.** "three thirty" on its own is "three thirty-year-olds"
or "ten fifteen twenty" as often as it is a time, so a rewrite needs a cue:
at/around/about/by, am/pm, o'clock, past/to, a month name, or the `Nth of the
Nth` shape. Half of `cases-en.yaml` is text that looks like a date and is not.
A transform that rewrites correct text is worse than one that never fires,
because it runs on every transcript and nobody watches it happen.

The judgement calls, each one a case in the set:

- **"seven o'clock" stays "7 o'clock"**, not `7:00`. The speaker said no
  minutes and `:00` is two digits they did not dictate. Digits go where digits
  were said, and "o'clock" is a word.
- **"noon" and "midnight" stay words** for the same reason.
- **Minutes under ten need "oh five" or "05".** "at two three" is not 2:03 in
  anybody's mouth; "at two oh five" is.
- **A bare `H MM` caps the hour at 12.** "at twenty twenty-six" is a year. The
  cost is that a 24-hour time said in English — "at fifteen thirty" — is left
  alone.
- **`MM to H` needs a lead cue**, at/around/about/by. "five to ten people" and
  "from ten to twelve" are ranges, and nothing in the words separates them from
  a time. `MM past H` does not need one: "past" followed by an hour is not a
  range.
- **Bare "am" needs a lead cue too.** "one am ready" is a sentence. "at seven
  am" is a time.
- **"3pm" and "July 3rd" are left alone.** The digits are already there and the
  only edit left is a space or a suffix, which is typography rather than a date
  being written down. "July 3rd" was one of four edits this stage made to 925
  archived clips and the only one that changed text nothing was wrong with.
- **A lone ordinal and a lone year are left alone.** "the fifteenth" and
  "twenty twenty-six" are the numbers stage's job. A date here needs a month
  name or the `Nth of the Nth` shape.
- **"second" is an ordinal here.** It is a unit of time far more often, and the
  numbers transform leaves it out for that reason — "a thirty second timeout"
  must not become "a 32nd timeout". Every ordinal here stands next to a month
  name or another ordinal, where a duration cannot be meant.

Score with `score.py --lang en` beside this file, or `ParrotFlow --eval
dates_en`.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import engine  # noqa: E402 — the path above is what makes it importable

# --- the words ---------------------------------------------------------------

UNITS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9,
}
ONES = {
    "zero": 0, "oh": 0, **UNITS,
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
    "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
    "nineteen": 19,
}
# "fourty" is how the decoder spells it about a tenth of the time.
TENS = {
    "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50,
    "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
}
ORDINAL_ONES = {
    "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
    "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11,
    "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
    "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
}
ORDINAL_TENS = {"twentieth": 20, "thirtieth": 30}
MONTHS = [
    "January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December",
]

LEAD = ("at", "around", "about", "by")

# A noun right after a number pair means the pair was counting, not telling the
# time: "two fifteen minute breaks", "five to ten people".
STOP_AFTER = {
    "minute", "minutes", "hour", "hours", "second", "seconds", "day", "days",
    "week", "weeks", "month", "months", "year", "years", "year-old",
    "year-olds", "percent", "people", "person", "kids", "men", "women",
    "hundred", "thousand", "million", "billion", "dollars", "euros", "pounds",
    "degrees", "miles", "kilometres", "kilometers", "pages", "times",
    "options", "option", "o'clock", "oclock",
}

# A range, not a clock. "from ten to twelve", "between two and three".
RANGE_BEFORE = re.compile(r"\b(?:from|between)\s+$", re.I)
WORD_BEFORE = re.compile(r"([\w'’-]+)\s*$")

# --- the patterns ------------------------------------------------------------

NUM = (r"(?:\d{1,2}"
       rf"|(?:{engine.alt(TENS)})[\s-](?:{engine.alt(UNITS)})"
       rf"|{engine.alt(TENS)}|{engine.alt(ONES)})")
# Minutes also have the "oh five" form the hour never has.
MIN = rf"(?:0\d|(?:oh|o)[\s-](?:{engine.alt(UNITS)})|{NUM})"
ORD = (rf"(?:(?:{engine.alt(ORDINAL_TENS)})"
       rf"|(?:{engine.alt(TENS)})[\s-](?:{engine.alt(ORDINAL_ONES)})"
       rf"|{engine.alt(ORDINAL_ONES)}|\d{{1,2}}(?:st|nd|rd|th))")
YEAR = (r"(?:\d{4}"
        rf"|(?:nineteen|twenty)[\s-](?:{NUM})"
        rf"|two\s+thousand(?:\s+and)?(?:\s+(?:{NUM}))?)")
MERIDIEM = r"(?:[ap]\.m\.|[ap]m\b)"
MONTH = engine.alt(MONTHS)

# --- reading a number out of one span ----------------------------------------


def read_number(text):
    """0–99 from words or digits, or None."""
    words = re.sub(r"[-\s]+", " ", (text or "").strip().lower()).split()
    if len(words) == 1:
        if words[0].isdigit():
            return int(words[0])
        return ONES.get(words[0], TENS.get(words[0]))
    if len(words) == 2:
        first, last = words
        if first in ("oh", "o") and last in UNITS:
            return UNITS[last]
        if first in TENS and last in UNITS:
            return TENS[first] + UNITS[last]
    return None


def read_ordinal(text):
    """1–99 from an ordinal, word or "3rd", or None."""
    raw = re.sub(r"[-\s]+", " ", (text or "").strip().lower())
    digits = re.fullmatch(r"(\d{1,2})(?:st|nd|rd|th)", raw)
    if digits:
        return int(digits.group(1))
    words = raw.split()
    if len(words) == 1:
        return ORDINAL_ONES.get(words[0], ORDINAL_TENS.get(words[0]))
    if len(words) == 2 and words[0] in TENS:
        unit = ORDINAL_ONES.get(words[1])
        return TENS[words[0]] + unit if unit and unit <= 9 else None
    return None


def read_year(text):
    """1000–2999 from a spoken year, or None."""
    raw = re.sub(r"[-\s]+", " ", (text or "").strip().lower())
    if raw.isdigit():
        return int(raw) if 1000 <= int(raw) <= 2999 else None
    if raw.startswith("two thousand"):
        rest = raw[len("two thousand"):].removeprefix(" and").strip()
        if not rest:
            return 2000
        value = read_number(rest)
        return 2000 + value if value is not None else None
    for lead, base in (("nineteen", 1900), ("twenty", 2000)):
        if raw.startswith(lead + " "):
            value = read_number(raw[len(lead):])
            return base + value if value is not None else None
    return None


def word_after(text, at):
    """The next word after offset `at`, lowercased, or "" at the end."""
    found = re.match(r"\s*([\w'’-]+)", text[at:])
    return found.group(1).lower() if found else ""


def word_before(text, at):
    """The word ending at offset `at`, lowercased, or ""."""
    found = WORD_BEFORE.search(text[:at])
    return found.group(1).lower() if found else ""


def clock(hour, minute=None):
    return f"{hour}:{minute:02d}" if minute is not None else str(hour)


# --- what the rules write ----------------------------------------------------

def hour_minute(m, text):
    """"at ten fifteen" -> "at 10:15"; "three thirty pm" -> "3:30 pm"."""
    lead, mer = m.group("lead"), m.group("mer")
    if not lead and not mer:
        return None
    hour, minute = read_number(m.group("h")), read_number(m.group("m"))
    if hour is None or not 1 <= hour <= 12:
        return None
    if minute is None or not 0 <= minute <= 59:
        return None
    # Under ten only when it was dictated that way.
    if minute < 10 and not re.match(r"(?i)^(?:0\d|oh|o[\s-])", m.group("m").strip()):
        return None
    following = word_after(text, m.end())
    if following in STOP_AFTER or read_number(following) is not None:
        return None
    if RANGE_BEFORE.search(text[:m.start()]):
        return None
    return ((lead + " " if lead else "") + f"{hour}:{minute:02d}"
            + (" " + mer if mer else ""))


def oclock(m, _text):
    """"seven o'clock" -> "7 o'clock". The minutes were not said."""
    hour = read_number(m.group("h"))
    if hour is None or not 1 <= hour <= 12:
        return None
    return f"{hour} {m.group('oc')}"


def named_fraction(m, text):
    """"half past two" -> "2:30"; "quarter to three" -> "2:45"."""
    kind, hour = m.group("kind").lower(), read_number(m.group("h"))
    if hour is None or not 1 <= hour <= 12:
        return None
    if kind == "half" and m.group("dir").lower() == "to":
        return None  # "half to three" is not English.
    if RANGE_BEFORE.search(text[:m.start()]):
        return None
    if word_after(text, m.end()) in STOP_AFTER:
        return None
    if m.group("dir").lower() == "past":
        return clock(hour, 30 if kind == "half" else 15)
    return clock(hour - 1 or 12, 45)


def minutes_past(m, text):
    """"twenty past four" -> "4:20"; "at ten to six" -> "5:50"."""
    minute, hour = read_number(m.group("m")), read_number(m.group("h"))
    if minute is None or hour is None:
        return None
    if not 1 <= hour <= 12 or minute % 5 or not 5 <= minute <= 55:
        return None
    to = m.group("dir").lower() == "to"
    # "to" without a cue is a range: "five to ten people".
    if to and not m.group("lead"):
        return None
    if RANGE_BEFORE.search(text[:m.start()]):
        return None
    if read_number(word_before(text, m.start())) is not None:
        return None
    following = word_after(text, m.end())
    if following in STOP_AFTER or read_number(following) is not None:
        return None
    lead = m.group("lead")
    written = clock(hour - 1 or 12, 60 - minute) if to else clock(hour, minute)
    return (lead + " " if lead else "") + written


def hour_meridiem(m, _text):
    """"three pm" -> "3 pm". No minutes were said, so none are written.

    "3pm" is left alone. The hour is already a digit, so the only edit left is
    inserting a space, and that is typography rather than a time being written
    down — the same call as "July 3rd" in `month_day`.
    """
    mer = m.group("mer")
    if m.group("h").isdigit():
        return None
    if not m.group("lead") and mer.lower() == "am":
        return None  # "one am ready" is a sentence.
    hour = read_number(m.group("h"))
    if hour is None or not 1 <= hour <= 12:
        return None
    lead = m.group("lead")
    return (lead + " " if lead else "") + f"{hour} {mer}"


def month_day(m, _text):
    """"March third twenty twenty-six" -> "March 3, 2026".

    "July 3rd" with no year is left as it is: the day is already a digit and
    the only edit left would be dropping the suffix. With a year the suffix
    does go, because the comma has to be inserted anyway.
    """
    if re.fullmatch(r"\d{1,2}(?:st|nd|rd|th)?", m.group("d")) and not m.group("y"):
        return None
    day = read_ordinal(m.group("d"))
    if day is None:
        day = read_number(m.group("d"))
    if day is None or not 1 <= day <= 31:
        return None
    year = read_year(m.group("y")) if m.group("y") else None
    if m.group("y") and year is None:
        return None
    return f"{m.group('mon')} {day}" + (f", {year}" if year else "")


def day_month(m, _text):
    """"the third of March" -> "3 March". The "the" goes with it."""
    day = read_ordinal(m.group("d"))
    if day is None or not 1 <= day <= 31:
        return None
    year = read_year(m.group("y")) if m.group("y") else None
    if m.group("y") and year is None:
        return None
    return f"{day} {m.group('mon')}" + (f" {year}" if year else "")


def day_of_month_number(m, text):
    """"the tenth of the twelfth" -> "10/12"."""
    day, month = read_ordinal(m.group("d")), read_ordinal(m.group("m"))
    if day is None or month is None:
        return None
    if not 1 <= day <= 31 or not 1 <= month <= 12:
        return None
    if word_after(text, m.end()) in STOP_AFTER:
        return None
    return f"{day}/{month}"


# Order is the whole of rule precedence: dates before times, and the longest
# form of a time before its shorter ones.
RULES = [(name, re.compile(pattern, re.I), handler) for name, pattern, handler in [
    ("the Nth of the Nth",
     rf"\bthe\s+(?P<d>{ORD})\s+of\s+the\s+(?P<m>{ORD})\b",
     day_of_month_number),
    ("day of month",
     rf"\b(?:the\s+)?(?P<d>{ORD})\s+of\s+(?P<mon>{MONTH})(?:,?\s+(?P<y>{YEAR}))?\b",
     day_month),
    ("month day",
     rf"\b(?P<mon>{MONTH})\s+(?P<d>{ORD}|\d{{1,2}})(?:,?\s+(?P<y>{YEAR}))?\b",
     month_day),
    ("half or quarter",
     rf"\b(?:a\s+)?(?P<kind>half|quarter)\s+(?P<dir>past|to)\s+(?P<h>{NUM})\b",
     named_fraction),
    ("minutes past or to",
     rf"(?:\b(?P<lead>{'|'.join(LEAD)})\s+)?\b(?P<m>{NUM})\s+(?P<dir>past|to)"
     rf"\s+(?P<h>{NUM})\b",
     minutes_past),
    ("hour and minutes",
     rf"(?:\b(?P<lead>{'|'.join(LEAD)})\s+)?(?<![:\dh])\b(?P<h>{NUM})[\s-]+"
     rf"(?P<m>{MIN})(?:\s+(?P<mer>{MERIDIEM}))?",
     hour_minute),
    ("o'clock",
     rf"(?<![:\dh])\b(?P<h>{NUM})\s+(?P<oc>o\s?['’]?\s?clock)\b",
     oclock),
    ("hour am or pm",
     rf"(?:\b(?P<lead>{'|'.join(LEAD)})\s+)?(?<![:\dh])\b(?P<h>{NUM})\s*"
     rf"(?P<mer>{MERIDIEM})",
     hour_meridiem),
]]


def gate_parts():
    """The `when:` regex, in fragments. See `engine.when`.

    Every rule needs a cue word beside a number, so the gate is that pair and
    not the grammar: one cue list, one token list. A month name on its own is
    deliberately not a cue — it would open the gate on every sentence
    containing "may".
    """
    cues = list(LEAD) + ["past", "to", "of"] + MONTHS
    tokens = (set(ONES) | set(TENS) | set(ORDINAL_ONES) | set(ORDINAL_TENS)
              | set(MONTHS))
    return [
        r"\b(?:o\s?['’]?\s?clock|[ap]\.m\.|pm)\b",
        r"\b(?:a\s+)?(?:half|quarter)\s+(?:past|to)\b",
        rf"\b(?:{engine.alt(cues)})\s+(?:the\s+)?"
        rf"(?:{engine.alt(tokens)}|\d{{1,2}}(?:st|nd|rd|th)?)\b",
    ]


if __name__ == "__main__":
    engine.main(sys.modules[__name__])
