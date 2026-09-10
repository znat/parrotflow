#!/usr/bin/env python3
"""English dates and clock times, written the way they were said.

"at ten fifteen" -> "at 10:15". "March third twenty twenty-six" -> "March 3,
2026". Transcript in, rewrite out. Publishes `count`, how many spans it
rewrote, and `applied`, the rules that fired.

    - name: dates_en
      description: dictated dates and clock times as digits
      command: examples/dates/en.py
      returns: json
      tests: examples/dates/cases-en.yaml

    pipeline:
      - transform: dates_en     # above numbers_en, which eats the same words

No cue, no rewrite: a time needs at/around/by, am/pm, o'clock, past/to, a month
name, or the `Nth of the Nth` shape. Half of `cases-en.yaml` is text that looks
like a date and is not. `engine.py` beside this file holds the loop, the JSON
protocol and the number words, and says how to add a language.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import engine  # noqa: E402 — the path above is what makes it importable

# --- the words ---------------------------------------------------------------

WORDS = engine.Words(
    "en",
    # "second" is not in the numbers grammar; see the header.
    ordinals={"second": 2},
    # The decoder writes a dictated nought "o" as often as "oh". It is not a
    # number word on its own, so it is a spelling of zero and nothing else.
    zeros={"o"},
)
UNITS, ONES, TENS = WORDS.units, WORDS.ones, WORDS.tens
ORDINAL_ONES, ORDINAL_TENS = WORDS.ordinals, WORDS.ordinal_tens
read_number, read_ordinal, read_year = WORDS.number, WORDS.ordinal, WORDS.year

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
    following = engine.word_after(text, m.end())
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
    if engine.word_after(text, m.end()) in STOP_AFTER:
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
    if read_number(engine.word_before(text, m.start())) is not None:
        return None
    following = engine.word_after(text, m.end())
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
    if engine.word_after(text, m.end()) in STOP_AFTER:
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


if __name__ == "__main__":
    engine.main(sys.modules[__name__])
