#!/usr/bin/env python3
"""Dictated dates and clock times, written the way they were said. Transcript on
stdin, rewrite on stdout.

    - name: dates
      description: dictated dates and clock times as digits
      command: examples/dates/dates.py
      returns: json

    pipeline:
      - transform: dates
        when: <the regex printed by `dates.py --when`>

`returns: json` sends `ctx.language` in and publishes `dates.count`, how many
spans were rewritten, and `dates.applied`, the names of the rules that fired.

**A dictated date already carries its format.** "le dix du douze" is `10/12`
because the speaker chose day-then-month; "March third twenty twenty-six" is
`March 3, 2026` because they chose month-then-day. Nothing here is told a
target format and nothing here reads a calendar: no "next Tuesday", no year
invented for a date that was said without one. The shape is in the utterance.
The same idea, and why the older `DateRewriter.swift` was parked for it, is in
that file's header.

**Before `numbers`, on words.** Measured on the numbers stage: "three thirty",
"at ten fifteen", "half past two", "March third", "trois heures et demie" and
"le trois décembre" all come back unchanged, while "à dix heures quinze"
becomes "à 10 heures 15" and "le dix du douze" becomes "le 10 du 12". Once
numbers has run the words are gone. So this reads the words first — and it also
accepts digits, because the decoder emits them either way ("March 3rd 2026",
"at 10 15").

**The number words come from `numbers.py`.** `../numbers/numbers.py` is loaded
by path and its `ENGLISH` and `FRENCH` grammars are where every unit, teen,
tens and ordinal word here comes from. Two tables of number words in one
pipeline is two tables to fix when a word is missing from one of them. What is
*not* borrowed is the parser: `numbers.read` answers "rewrite this sentence",
and the question here is "what number is in this span" — "three" is 3 to a
clock and stays a word to `numbers`, which has a floor under ten. So the span
readers below are this file's, and only the vocabulary is shared.

So `dates/` does not stand alone. Copy it out to customise it and you must copy
`numbers/` beside it, or the import fails — and when it fails this stage
returns the transcript untouched rather than raising, which is the same
fail-open every other stage keeps.

**No cue, no rewrite.** "three thirty" on its own is "three thirty-year-olds"
or "ten fifteen twenty" as often as it is a time, so a rewrite needs a cue:
at/around/about/by, à/vers, am/pm, o'clock, past/to, heures, midi/minuit,
et demie, et quart, moins, a month name, or the `Nth of the Nth` shape. A third
of `cases.yaml` is text that looks like a date and is not. A transform that
rewrites correct text is worse than one that never fires, because it runs on
every transcript and nobody watches it happen.

The judgement calls, each one a case in the set:

- **"seven o'clock" stays "7 o'clock"**, not `7:00`. The speaker said no
  minutes and `:00` is two digits they did not dictate. Digits go where digits
  were said, and "o'clock" is a word.
- **"noon" and "midnight" stay words** for the same reason. French `midi et
  demi` does become `12h30`, because there the half hour is dictated and `12h30`
  is how it is written.
- **English minutes under ten need "oh five" or "05".** "at two three" is not
  2:03 in anybody's mouth; "at two oh five" is.
- **English bare `H MM` caps the hour at 12.** "at twenty twenty-six" is a
  year. The cost is that a 24-hour time said in English — "at fifteen thirty" —
  is left alone.
- **`MM to H` needs a lead cue**, `at`/`around`/`about`/`by`. "five to ten
  people" and "from ten to twelve" are ranges, and there is nothing in the
  words that separates them from a time. `MM past H` does not need one: "past"
  followed by an hour is not a range.
- **Bare "am" needs a lead cue too.** "one am ready" is a sentence. "at seven
  am" is a time.
- **French bare `H heures` fires at 13 and above, or after à/vers.** "il y a
  trois heures" is a duration, and so is "pendant trois heures"; "vingt heures"
  is a time. A duration marker before the number declines it outright, and so
  does a `de` after it — "trois heures de route". The known miss is a long
  duration with no marker: "j'ai dormi vingt heures" becomes "j'ai dormi 20h".
- **French keeps "le".** "le trois décembre" is "le 3 décembre" and "le dix du
  douze" is "le 10/12" — that is how the date is written in French. English
  "the third of March" drops its "the", because "the 3 March" is not.
- **French "a" is not "à".** The unaccented verb was in the lead list and
  turned "il a trois heures d'avance" into "il a 3h d'avance". Accented forms
  only now, and an elided "d'" after the hour declines it — "à trois heures
  d'ici" is a distance.
- **"3pm" and "July 3rd" are left alone.** The digits are already there and the
  only edit left is a space or a suffix, which is typography rather than a date
  being written down. "July 3rd" was one of four edits this stage made to 925
  archived clips and the only one that changed text nothing was wrong with.
- **"premier" is written "1er"**, the one ordinal French keeps in a date.
- **A lone ordinal and a lone year are left alone.** "the fifteenth" and
  "twenty twenty-six" are the numbers stage's job. A date here needs a month
  name or the `Nth of the Nth` shape.
- **"second" is added back to the English ordinals.** `numbers` leaves it out
  on purpose — "a thirty second timeout" would become "a 32nd timeout" — but
  every ordinal here stands next to a month name or another ordinal, where a
  duration cannot be meant.

Score the set with `score.py` beside this file, or `ParrotFlow --eval
examples/transforms/dates/cases.yaml`.
"""
import importlib.util
import json
import os
import re
import sys
from pathlib import Path

# The numbers transform, beside this one. A path rather than a package import,
# because `examples/transforms/` is copied whole into
# `~/.config/parrotflow/transforms/examples/` and neither copy is on sys.path.
# Loaded under a name of its own: `numbers` is a standard library module.
NUMBERS = Path(__file__).resolve().parent.parent / "numbers" / "numbers.py"


def load_numbers():
    spec = importlib.util.spec_from_file_location("parrotflow_numbers", NUMBERS)
    if spec is None or spec.loader is None:
        raise ImportError(f"no numbers transform at {NUMBERS}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


try:
    numbers = load_numbers()
    MISSING = None
except Exception as error:  # noqa: BLE001 — any failure means "no vocabulary"
    numbers, MISSING = None, f"{NUMBERS} could not be loaded: {error}"

# Filled by `build()` from the numbers grammars. Empty means the import failed
# and every rewrite returns its input.
EN_ONES, EN_TENS, EN_UNITS = {}, {}, {}
EN_ORD_ONES, EN_ORD_TENS = {}, {}
FR_ONES, FR_TENS, FR_UNITS = {}, {}, {}
FR_FIRST = set()

MONTHS_EN = [
    "January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December",
]
MONTHS_FR = [
    "janvier", "février", "fevrier", "mars", "avril", "mai", "juin",
    "juillet", "août", "aout", "septembre", "octobre", "novembre",
    "décembre", "decembre",
]


def alt(words):
    """An alternation, longest first — "quatorze" must beat "quatre".

    Alphabetical within a length, so a set of words always prints the same
    regex. Without the tie-break `--when` printed a different line every run,
    and the one in config.yaml could never be checked against it.
    """
    return "|".join(re.escape(w) for w in sorted(words, key=lambda w: (-len(w), w)))


# --- reading a number out of one span ---------------------------------------

def read_en(text):
    """0–99 from English words or digits, or None."""
    words = re.sub(r"[-\s]+", " ", (text or "").strip().lower()).split()
    if len(words) == 1:
        if words[0].isdigit():
            return int(words[0])
        return EN_ONES.get(words[0], EN_TENS.get(words[0]))
    if len(words) == 2:
        first, last = words
        if first in ("oh", "o") and last in EN_UNITS:
            return EN_UNITS[last]
        if first in EN_TENS and last in EN_UNITS:
            return EN_TENS[first] + EN_UNITS[last]
    return None


def read_fr(text):
    """0–99 from French words or digits, or None.

    Hyphen and space are the same separator, so "dix-sept" and "dix sept" read
    alike — but the whole form is looked up before it is split, because a table
    may hold either. "dix-sept" is not in the numbers vocabulary at all: its
    tokeniser splits hyphens and its grammar adds 10 and 7, so that sum is
    done here.
    """
    raw = (text or "").strip().lower()
    if raw.isdigit():
        return int(raw)
    joined = re.sub(r"[-\s]+", "-", raw)
    if joined in FR_ONES or joined in FR_TENS:
        return FR_ONES.get(joined, FR_TENS.get(joined))
    parts = joined.split("-")
    if len(parts) == 2 and parts[0] in FR_TENS and parts[1] in FR_UNITS:
        return FR_TENS[parts[0]] + FR_UNITS[parts[1]]
    if len(parts) == 2 and FR_ONES.get(parts[0]) == 10 and parts[1] in FR_UNITS:
        unit = FR_UNITS[parts[1]]
        return 10 + unit if 7 <= unit <= 9 else None
    if len(parts) == 3 and parts[0] in FR_TENS and parts[1] == "et":
        return FR_TENS[parts[0]] + 1 if parts[2] in ("un", "une") else None
    return None


def read_ordinal(text):
    """1–99 from an English ordinal, word or "3rd", or None."""
    raw = re.sub(r"[-\s]+", " ", (text or "").strip().lower())
    digits = re.fullmatch(r"(\d{1,2})(?:st|nd|rd|th)", raw)
    if digits:
        return int(digits.group(1))
    words = raw.split()
    if len(words) == 1:
        return EN_ORD_ONES.get(words[0], EN_ORD_TENS.get(words[0]))
    if len(words) == 2 and words[0] in EN_TENS:
        unit = EN_ORD_ONES.get(words[1])
        return EN_TENS[words[0]] + unit if unit and unit <= 9 else None
    return None


def read_year_en(text):
    """1000–2999 from an English year, or None."""
    raw = re.sub(r"[-\s]+", " ", (text or "").strip().lower())
    if raw.isdigit():
        return int(raw) if 1000 <= int(raw) <= 2999 else None
    if raw.startswith("two thousand"):
        rest = raw[len("two thousand"):].removeprefix(" and").strip()
        if not rest:
            return 2000
        value = read_en(rest)
        return 2000 + value if value is not None else None
    for lead, base in (("nineteen", 1900), ("twenty", 2000)):
        if raw.startswith(lead + " "):
            value = read_en(raw[len(lead):])
            return base + value if value is not None else None
    return None


def read_year_fr(text):
    """1000–2999 from a French year, or None. "deux mille" and digits only —
    "mille neuf cent quatre-vingt-dix-neuf" is not a year anybody dictates."""
    raw = re.sub(r"[-\s]+", " ", (text or "").strip().lower())
    if raw.isdigit():
        return int(raw) if 1000 <= int(raw) <= 2999 else None
    if raw.startswith("deux mille"):
        rest = raw[len("deux mille"):].strip()
        if not rest:
            return 2000
        value = read_fr(rest)
        return 2000 + value if value is not None else None
    return None


# --- guards -----------------------------------------------------------------

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
EN_RANGE_BEFORE = re.compile(r"\b(?:from|between)\s+$", re.I)

# A span of time, not a point in it. Anchored right before the number, so
# "dans la salle à dix heures" is not caught by "dans".
FR_DURATION_BEFORE = re.compile(
    r"\b(?:il\s+y\s+a|pendant|depuis|durant|environ|dans|toutes\s+les"
    r"|plus\s+de|moins\s+de|au\s+bout\s+de|en|après|apres)\s+$", re.I)

# "à dix heures" is a time; "trois heures" on its own before 13:00 is not.
# Accents only. Bare "a" is the verb far more often than a mistyped "à", and it
# turned "il a trois heures d'avance" into "il a 3h d'avance".
FR_LEAD_BEFORE = re.compile(r"\b(?:à|vers|dès)\s+$", re.I)

# "trois heures de route", "24 heures sur 24", "à trois heures d'ici".
FR_NOT_A_CLOCK_AFTER = {"de", "du", "des", "sur", "devant", "d"}

WORD_BEFORE = re.compile(r"([\w'’-]+)\s*$")


def word_after(text, at):
    """The next word after offset `at`, lowercased, or "" at the end."""
    found = re.match(r"\s*([\w'’-]+)", text[at:])
    return found.group(1).lower() if found else ""


def word_before(text, at):
    """The word ending at offset `at`, lowercased, or ""."""
    found = WORD_BEFORE.search(text[:at])
    return found.group(1).lower() if found else ""


def counts_as_number(word, lang):
    """Whether the word beside a match is itself a number — "ten fifteen
    twenty" is three numbers, not a time."""
    return (read_en(word) if lang == "en" else read_fr(word)) is not None


# --- what the rules write ---------------------------------------------------

EN_LEAD_WORDS = ("at", "around", "about", "by")
EN_LEAD = "(?:" + "|".join(EN_LEAD_WORDS) + ")"
EN_MER = r"(?:[ap]\.m\.|[ap]m\b)"


def clock(hour, minute=None):
    return f"{hour}:{minute:02d}" if minute is not None else str(hour)


def en_hour_minute(m, text):
    """"at ten fifteen" -> "at 10:15"; "three thirty pm" -> "3:30 pm"."""
    lead, mer = m.group("lead"), m.group("mer")
    if not lead and not mer:
        return None
    hour, minute = read_en(m.group("h")), read_en(m.group("m"))
    if hour is None or not 1 <= hour <= 12:
        return None
    if minute is None or not 0 <= minute <= 59:
        return None
    # Under ten only when it was dictated that way.
    if minute < 10 and not re.match(r"(?i)^(?:0\d|oh|o[\s-])", m.group("m").strip()):
        return None
    following = word_after(text, m.end())
    if following in STOP_AFTER or counts_as_number(following, "en"):
        return None
    if EN_RANGE_BEFORE.search(text[:m.start()]):
        return None
    return ((lead + " " if lead else "") + f"{hour}:{minute:02d}"
            + (" " + mer if mer else ""))


def en_oclock(m, _text):
    """"seven o'clock" -> "7 o'clock". The minutes were not said."""
    hour = read_en(m.group("h"))
    if hour is None or not 1 <= hour <= 12:
        return None
    return f"{hour} {m.group('oc')}"


def en_named_fraction(m, text):
    """"half past two" -> "2:30"; "quarter to three" -> "2:45"."""
    kind, hour = m.group("kind").lower(), read_en(m.group("h"))
    if hour is None or not 1 <= hour <= 12:
        return None
    if kind == "half" and m.group("dir").lower() == "to":
        return None  # "half to three" is not English.
    if EN_RANGE_BEFORE.search(text[:m.start()]):
        return None
    if word_after(text, m.end()) in STOP_AFTER:
        return None
    if m.group("dir").lower() == "past":
        return clock(hour, 30 if kind == "half" else 15)
    return clock(hour - 1 or 12, 45)


def en_minutes_past(m, text):
    """"twenty past four" -> "4:20"; "at ten to six" -> "5:50"."""
    minute, hour = read_en(m.group("m")), read_en(m.group("h"))
    if minute is None or hour is None:
        return None
    if not 1 <= hour <= 12 or minute % 5 or not 5 <= minute <= 55:
        return None
    to = m.group("dir").lower() == "to"
    # "to" without a cue is a range: "five to ten people".
    if to and not m.group("lead"):
        return None
    before = text[:m.start()]
    if EN_RANGE_BEFORE.search(before):
        return None
    if counts_as_number(word_before(text, m.start()), "en"):
        return None
    following = word_after(text, m.end())
    if following in STOP_AFTER or counts_as_number(following, "en"):
        return None
    lead = m.group("lead")
    written = clock(hour - 1 or 12, 60 - minute) if to else clock(hour, minute)
    return (lead + " " if lead else "") + written


def en_hour_meridiem(m, _text):
    """"three pm" -> "3 pm". No minutes were said, so none are written.

    "3pm" is left alone. The hour is already a digit, so the only edit left is
    inserting a space, and that is typography rather than a time being written
    down — the same call as "July 3rd" in `en_month_day`.
    """
    mer = m.group("mer")
    if m.group("h").isdigit():
        return None
    if not m.group("lead") and mer.lower() == "am":
        return None  # "one am ready" is a sentence.
    hour = read_en(m.group("h"))
    if hour is None or not 1 <= hour <= 12:
        return None
    lead = m.group("lead")
    return (lead + " " if lead else "") + f"{hour} {mer}"


def en_month_day(m, _text):
    """"March third twenty twenty-six" -> "March 3, 2026".

    "July 3rd" with no year is left as it is. The day is already a digit, so
    the only edit left would be dropping the suffix, and that is an opinion
    about typography rather than a date being written down. Measured: it was
    one of four edits this stage made to 925 archived clips, and the only one
    that changed text nothing was wrong with. With a year the suffix does go,
    because the comma has to be inserted anyway.
    """
    written_as_digits = re.fullmatch(r"\d{1,2}(?:st|nd|rd|th)?", m.group("d"))
    if written_as_digits and not m.group("y"):
        return None
    day = read_ordinal(m.group("d"))
    if day is None:
        day = read_en(m.group("d"))
    if day is None or not 1 <= day <= 31:
        return None
    year = read_year_en(m.group("y")) if m.group("y") else None
    if m.group("y") and year is None:
        return None
    return f"{m.group('mon')} {day}" + (f", {year}" if year else "")


def en_day_month(m, _text):
    """"the third of March" -> "3 March". The "the" goes with it."""
    day = read_ordinal(m.group("d"))
    if day is None or not 1 <= day <= 31:
        return None
    year = read_year_en(m.group("y")) if m.group("y") else None
    if m.group("y") and year is None:
        return None
    return f"{day} {m.group('mon')}" + (f" {year}" if year else "")


def en_day_of_month_number(m, text):
    """"the tenth of the twelfth" -> "10/12"."""
    day, month = read_ordinal(m.group("d")), read_ordinal(m.group("m"))
    if day is None or month is None:
        return None
    if not 1 <= day <= 31 or not 1 <= month <= 12:
        return None
    if word_after(text, m.end()) in STOP_AFTER:
        return None
    return f"{day}/{month}"


def fr_hour(m, text):
    """"dix heures quinze" -> "10h15"; "vingt heures" -> "20h"."""
    hour = read_fr(m.group("h"))
    if hour is None or not 0 <= hour <= 23:
        return None
    before = text[:m.start()]
    if FR_DURATION_BEFORE.search(before):
        return None
    # `word_after` reads "d'avance" whole, so the elision is split off first.
    following = word_after(text, m.end()).split("'")[0].split("\u2019")[0]
    if following in FR_NOT_A_CLOCK_AFTER:
        return None

    if m.group("half"):
        return f"{hour}h30"
    if m.group("quarter"):
        return f"{hour}h15"
    if m.group("lessquarter"):
        return f"{hour - 1 if hour else 23}h45"
    if m.group("less"):
        minute = read_fr(m.group("less"))
        if minute is None or not 1 <= minute <= 59:
            return None
        return f"{hour - 1 if hour else 23}h{60 - minute:02d}"
    if m.group("mm"):
        minute = read_fr(m.group("mm"))
        if minute is None or not 0 <= minute <= 59:
            return None
        return f"{hour}h{minute:02d}"
    # Nothing after "heures": a bare hour needs its own cue.
    if hour < 13 and not FR_LEAD_BEFORE.search(before):
        return None
    return f"{hour}h"


def fr_midi(m, _text):
    """"midi et demi" -> "12h30". Bare "midi" stays a word."""
    hour = 12 if m.group("w").lower() == "midi" else 0
    if m.group("half"):
        return f"{hour}h30"
    if m.group("quarter"):
        return f"{hour}h15"
    if m.group("lessquarter"):
        return f"{hour - 1 if hour else 23}h45"
    minute = read_fr(m.group("less"))
    if minute is None or not 1 <= minute <= 59:
        return None
    return f"{hour - 1 if hour else 23}h{60 - minute:02d}"


def fr_day_month(m, _text):
    """"le trois décembre" -> "le 3 décembre"; "le premier mai" -> "le 1er mai"."""
    raw = m.group("d").lower()
    if raw in FR_FIRST or raw == "1er":
        day, written = 1, "1er"
    else:
        day = read_fr(raw)
        if day is None:
            return None
        written = str(day)
    if not 1 <= day <= 31:
        return None
    year = read_year_fr(m.group("y")) if m.group("y") else None
    if m.group("y") and year is None:
        return None
    return f"{written} {m.group('mon')}" + (f" {year}" if year else "")


def fr_day_of_month_number(m, _text):
    """"le dix du douze" -> "le 10/12". The "le" stays: that is the French."""
    day, month = read_fr(m.group("d")), read_fr(m.group("m"))
    if day is None or month is None:
        return None
    if not 1 <= day <= 31 or not 1 <= month <= 12:
        return None
    return f"{m.group('le')} {day}/{month}"


# --- the grammar, built from the numbers vocabulary -------------------------

def patterns():
    """Every regex fragment, from the tables `build()` filled."""
    en_num = (r"(?:\d{1,2}"
              rf"|(?:{alt(EN_TENS)})[\s-](?:{alt(EN_UNITS)})"
              rf"|{alt(EN_TENS)}|{alt(EN_ONES)})")
    # Minutes also have the "oh five" form the hour never has.
    en_min = rf"(?:0\d|(?:oh|o)[\s-](?:{alt(EN_UNITS)})|{en_num})"
    en_ord = (rf"(?:(?:{alt(EN_ORD_TENS)})"
              rf"|(?:{alt(EN_TENS)})[\s-](?:{alt(EN_ORD_ONES)})"
              rf"|{alt(EN_ORD_ONES)}|\d{{1,2}}(?:st|nd|rd|th))")
    en_year = (r"(?:\d{4}"
               rf"|(?:nineteen|twenty)[\s-](?:{en_num})"
               rf"|two\s+thousand(?:\s+and)?(?:\s+(?:{en_num}))?)")
    # "dix-sept" is two words to the numbers tokeniser, so it is spelled here.
    fr_num = (r"(?:\d{1,2}"
              rf"|(?:{alt(FR_TENS)})[\s-]et[\s-](?:une?)"
              rf"|(?:{alt(FR_TENS)})[\s-](?:{alt(FR_UNITS)})"
              rf"|dix[\s-](?:sept|huit|neuf)"
              rf"|{alt(FR_TENS)}|{alt(FR_ONES)})")
    fr_year = rf"(?:\d{{4}}|deux\s+mille(?:\s+(?:{fr_num}))?)"
    return {
        "en_num": en_num, "en_min": en_min, "en_ord": en_ord,
        "en_year": en_year, "fr_num": fr_num, "fr_year": fr_year,
        "months_en": alt(MONTHS_EN), "months_fr": alt(MONTHS_FR),
        "fr_first": alt(FR_FIRST | {"1er"}),
    }


def rules(p):
    """Name, pattern, handler. Order is the only thing that separates them:
    dates before times, and the longest form of a time before its shorter ones.
    """
    # The tail a French hour can carry. One group set, shared by `heures` and
    # by `midi`/`minuit`, so the two cannot drift apart.
    tail = (r"(?:(?P<half>et\s+demie?)|(?P<quarter>et\s+quart)"
            r"|(?P<lessquarter>moins\s+le\s+quart)"
            rf"|moins\s+(?P<less>{p['fr_num']})|(?P<mm>{p['fr_num']}))")
    return {
        "en": [
            ("the Nth of the Nth",
             rf"\bthe\s+(?P<d>{p['en_ord']})\s+of\s+the\s+(?P<m>{p['en_ord']})\b",
             en_day_of_month_number),
            ("day of month",
             rf"\b(?:the\s+)?(?P<d>{p['en_ord']})\s+of\s+(?P<mon>{p['months_en']})"
             rf"(?:,?\s+(?P<y>{p['en_year']}))?\b",
             en_day_month),
            ("month day",
             rf"\b(?P<mon>{p['months_en']})\s+(?P<d>{p['en_ord']}|\d{{1,2}})"
             rf"(?:,?\s+(?P<y>{p['en_year']}))?\b",
             en_month_day),
            ("half or quarter",
             rf"\b(?:a\s+)?(?P<kind>half|quarter)\s+(?P<dir>past|to)\s+"
             rf"(?P<h>{p['en_num']})\b",
             en_named_fraction),
            ("minutes past or to",
             rf"(?:\b(?P<lead>{EN_LEAD})\s+)?\b(?P<m>{p['en_num']})\s+"
             rf"(?P<dir>past|to)\s+(?P<h>{p['en_num']})\b",
             en_minutes_past),
            ("hour and minutes",
             rf"(?:\b(?P<lead>{EN_LEAD})\s+)?(?<![:\dh])\b(?P<h>{p['en_num']})"
             rf"[\s-]+(?P<m>{p['en_min']})(?:\s+(?P<mer>{EN_MER}))?",
             en_hour_minute),
            ("o'clock",
             rf"(?<![:\dh])\b(?P<h>{p['en_num']})\s+(?P<oc>o\s?['’]?\s?clock)\b",
             en_oclock),
            ("hour am or pm",
             rf"(?:\b(?P<lead>{EN_LEAD})\s+)?(?<![:\dh])\b(?P<h>{p['en_num']})"
             rf"\s*(?P<mer>{EN_MER})",
             en_hour_meridiem),
        ],
        "fr": [
            ("le N du N",
             rf"\b(?P<le>[Ll]e)\s+(?P<d>{p['fr_num']})\s+du\s+"
             rf"(?P<m>{p['fr_num']})\b",
             fr_day_of_month_number),
            ("jour mois",
             rf"\b(?P<d>{p['fr_first']}|{p['fr_num']})\s+"
             rf"(?P<mon>{p['months_fr']})(?:\s+(?P<y>{p['fr_year']}))?\b",
             fr_day_month),
            ("midi ou minuit",
             rf"\b(?P<w>midi|minuit)\s+{tail}",
             fr_midi),
            ("heures",
             rf"(?<![\dh])\b(?P<h>{p['fr_num']})\s+heures?\b(?:\s+{tail})?",
             fr_hour),
        ],
    }


COMPILED = {}


def build():
    """Fill the word tables from the numbers grammars and compile the rules."""
    en, fr = numbers.ENGLISH, numbers.FRENCH
    EN_ONES.update(en.units)
    EN_ONES.update(en.teens)
    EN_TENS.update(en.tens)
    EN_UNITS.update({w: v for w, v in en.units.items() if 1 <= v <= 9})
    EN_ORD_ONES.update(en.ordinal_units)
    EN_ORD_ONES.update(en.ordinal_teens)
    # See the docstring: `numbers` drops "second" to protect durations, and no
    # ordinal here stands anywhere a duration could.
    EN_ORD_ONES["second"] = 2
    EN_ORD_TENS.update(en.ordinal_tens)
    FR_ONES.update(fr.units)
    FR_ONES.update(fr.teens)
    FR_TENS.update(fr.tens)
    FR_UNITS.update({w: v for w, v in fr.units.items() if 1 <= v <= 9})
    # "unième" is also 1 there, but only ever after a tens word — never a day.
    FR_FIRST.update(w for w, v in fr.ordinal_units.items()
                    if v == 1 and w.startswith("prem"))

    p = patterns()
    COMPILED.update({
        lang: [(name, re.compile(pattern, re.I), handler)
               for name, pattern, handler in group]
        for lang, group in rules(p).items()
    })


if numbers is not None:
    build()


# --- running it -------------------------------------------------------------

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


def rewrite(text, language=None, applied=None):
    """The dates and times in `text`, written as they were spoken.

    No language means both grammars, in order. The cue words barely overlap —
    "heures" is not an English word and "o'clock" is not a French one — so a
    bare `echo | dates.py` still works.
    """
    applied = [] if applied is None else applied
    code = (language or "").lower()[:2]
    langs = [code] if code in COMPILED else list(COMPILED)
    for lang in langs:
        for name, pattern, handler in COMPILED[lang]:
            text = apply_rule(text, name, pattern, handler, applied)
    return text


# --- the `when:` condition --------------------------------------------------

# A word that can begin the second half of a date or a time: any number word
# either grammar knows, any ordinal, or a month.
def gate_tokens():
    words = set(EN_ONES) | set(EN_TENS) | set(EN_ORD_ONES) | set(EN_ORD_TENS)
    words |= set(FR_ONES) | set(FR_TENS) | FR_FIRST
    words |= {"oh"}
    return words


# A word that says the number after it is a date or a clock, not a count.
GATE_CUES = list(EN_LEAD_WORDS) + ["vers", "à", "du", "le", "past", "to", "of"]


def when():
    """The `when:` regex for the pipeline step, built from the cues above.

    A gate, not the grammar: it lets through everything the rules could fire
    on, and nothing else pays for a python3 start. Generated rather than typed,
    for the reason `numbers.gate` is — a gate that misses a word is a silent
    miss. `score.py` fails if a case that must change does not match it.

    Every rule needs a cue word beside a number, so the gate is that pair and
    not the grammar: one cue list, one token list, in that order. Written out
    per rule it was 4722 characters and unreadable in a config file.

    Slashes included. A `when:` between them is a regular expression and
    anything else is an expression over the scope, so the printed line is
    pasted as it stands. `(?i)` is stated rather than assumed: the pipeline
    compiles a `when:` case-insensitively already, but the regex is also read
    by `score.py` and by whoever pastes it somewhere else.

    A month name on its own is deliberately not a cue. It would open the gate
    on every sentence containing "may".
    """
    p = patterns()
    months = "|".join((p["months_en"], p["months_fr"]))
    token = f"{alt(gate_tokens())}|{months}|" + r"\d{1,2}(?:st|nd|rd|th)?"
    return "/(?i)" + "|".join([
        r"\b(?:heures?|midi|minuit|o\s?['’]?\s?clock|[ap]\.m\.|pm)\b",
        r"\b(?:a\s+)?(?:half|quarter)\s+(?:past|to)\b",
        rf"\b(?:{'|'.join(GATE_CUES)}|{months})\s+(?:the\s+)?(?:{token})\b",
    ]) + "/"


# --- entry point ------------------------------------------------------------

def main():
    if "--when" in sys.argv[1:]:
        if numbers is None:
            sys.exit(MISSING)
        print(when())
        return

    # ParrotFlow sets PARROTFLOW_PROTOCOL=json when the transform declares
    # `returns: json`, and then stdin is the envelope. Unset is the plain path,
    # which is what a bare `echo … | dates.py` gets.
    structured = os.environ.get("PARROTFLOW_PROTOCOL") == "json"
    raw = sys.stdin.read()
    envelope = json.loads(raw) if structured else {"text": raw}
    text = envelope["text"]
    language = (envelope.get("ctx") or {}).get("language")

    applied = []
    try:
        out = rewrite(text, language, applied)
    except Exception:
        # Fail open — never drop the whole transcript because a guard threw.
        # A missing numbers transform arrives here as an empty rule set, so it
        # is the same silent no-op rather than a stage that errors.
        out = text
        applied.clear()

    if not structured:
        sys.stdout.write(out)
        return
    print(json.dumps({
        "text": out,
        # Deduplicated: two times in one sentence name the rule once.
        "vars": {"count": len(applied),
                 "applied": ", ".join(dict.fromkeys(applied))},
    }))


if __name__ == "__main__":
    main()
