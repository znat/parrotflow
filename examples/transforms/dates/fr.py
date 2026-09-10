#!/usr/bin/env python3
"""Dates et heures dictées, écrites comme elles ont été dites.

"dix heures quinze" -> "10h15". "le trois décembre" -> "le 3 décembre".
Transcript in, rewrite out. Publishes `count`, the spans it rewrote, and
`applied`, the rules that fired.

    - name: dates_fr
      description: dictated dates and clock times as digits
      command: examples/dates/fr.py
      returns: json
      tests: examples/dates/cases-fr.yaml

    pipeline:
      - transform: dates_fr     # above numbers_fr, which eats the same words

No cue, no rewrite: `heures`, `midi`, `minuit`, `et demie`, `et quart`,
`moins`, a month name, or `<préposition> N du N`. An hour under 12 becomes the
next time it comes round — "à 4h" said at noon is 16h — unless a qualifier says
so or `--no-wall-clock` is on the `command:` line. `engine.py` holds the rest.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import engine  # noqa: E402 — the path above is what makes it importable

# --- les mots ----------------------------------------------------------------

WORDS = engine.Words("fr")
UNITS, ONES, TENS = WORDS.units, WORDS.ones, WORDS.tens
read_number, read_year = WORDS.number, WORDS.year

# The one ordinal a French date keeps. "1er" is the written form, which is not
# a word the numbers grammar reads.
FIRST = {word for word, value in WORDS.ordinals.items() if value == 1} | {"1er"}

MOIS = [
    "janvier", "février", "fevrier", "mars", "avril", "mai", "juin",
    "juillet", "août", "aout", "septembre", "octobre", "novembre",
    "décembre", "decembre",
]

# A span of time, not a point in it. Anchored right before the number, so
# "dans la salle à dix heures" is not caught by "dans".
DURATION_BEFORE = re.compile(
    r"\b(?:il\s+y\s+a|pendant|depuis|durant|environ|dans|toutes\s+les"
    r"|plus\s+de|moins\s+de|au\s+bout\s+de|en|après|apres)\s+$", re.I)

# "à dix heures" is a time; "trois heures" on its own before 13:00 is not.
LEAD_BEFORE = re.compile(r"\b(?:à|vers|dès)\s+$", re.I)

# A noun right after a two-digit year says it was counting: "le 12 mai 25
# personnes sont venues".
NOT_A_YEAR_AFTER = {
    "an", "ans", "personnes", "gens", "euros", "minutes", "secondes",
    "heures", "jours", "semaines", "mois", "pages", "fois", "mètres",
    "kilomètres", "degrés", "%",
}

# What introduces a written date. Longest first, so "à partir du" beats "du".
BEFORE_DATE = (r"(?:jusqu['\u2019]\s*au|[àa]\s+partir\s+du|d[èe]s\s+le"
               r"|du|au|le)")

# "trois heures de route", "24 heures sur 24", "à trois heures d'ici".
NOT_A_CLOCK_AFTER = {"de", "du", "des", "sur", "devant", "d"}

# Half of the day, named. The words are the same before the time and after it.
AFTERNOON = r"(?:apr[eè]s[\s-]midis?|aprems?|soirs?|soir[ée]es?)"
MORNING = r"(?:matins?|matin[ée]es?)"
PERIOD_WORD = re.compile(rf"^(?:{AFTERNOON}|{MORNING})$", re.I)
IS_MORNING = re.compile(rf"^{MORNING}$", re.I)
# How far back a "ce soir" or a "demain matin" still speaks for the time.
PERIOD_REACH = 5

# --- les motifs --------------------------------------------------------------

# "dix-sept" is spelled out: the tables stop at seize, and 17 to 19 are 10 plus
# a unit in this language.
NUM = (r"(?:\d{1,2}"
       rf"|(?:{engine.alt(TENS)})[\s-]et[\s-](?:une?)"
       rf"|(?:{engine.alt(TENS)})[\s-](?:{engine.alt(UNITS)})"
       rf"|dix[\s-](?:sept|huit|neuf)"
       rf"|{engine.alt(TENS)}|{engine.alt(ONES)})")
YEAR = rf"(?:\d{{4}}|deux\s+mille(?:\s+(?:{NUM}))?)"
MONTH = engine.alt(MOIS)
# The tail an hour can carry. One group set, shared by `heures` and by
# `midi`/`minuit`, so the two cannot drift apart.
TAIL = (r"(?:(?P<half>et\s+demie?)|(?P<quarter>et\s+quart)"
        r"|(?P<lessquarter>moins\s+le\s+quart)"
        rf"|moins\s+(?P<less>{NUM})|(?P<mm>{NUM}))")
# The hour, spoken or already written. `(?!\w)` is what leaves "15h12" alone:
# the digits after the h say it is written out and finished.
HOUR = rf"(?:(?P<hw>{NUM})\s+heures?\b|(?P<hd>\d{{1,2}})\s*h(?!\w))"
# Which half of the day, said after the time. Taken with it and not written.
PERIOD = rf"(?:\s+(?:de\s+l['\u2019]\s*|du\s+)(?P<period>{AFTERNOON}|{MORNING}))"

# --- ce que les règles écrivent ----------------------------------------------

def period_before(text):
    """The half of the day named in the last few words, or None.

    "demain matin à 4h" and "ce soir à 4h" say which 4h they mean without
    standing next to it. The nearest one wins.
    """
    for word in reversed(engine.split(text)[-PERIOD_REACH:]):
        if PERIOD_WORD.match(word):
            return word
    return None


def stated_hour(hour, period, text, start):
    """The hour the speaker meant, from the qualifier or from the clock.

    A qualifier decides on its own. Without one an hour under 12 is the next
    time that hour comes round, so "à 4h" is this afternoon until it is past
    four, and tomorrow morning after that.
    """
    named = period or period_before(text[:start])
    if named:
        if hour >= 12 or IS_MORNING.match(named):
            return hour
        return hour + 12
    if not engine.WALL_CLOCK or hour == 0 or hour >= 12:
        return hour
    current = engine.now().hour
    return hour if (hour - current) % 24 <= (hour + 12 - current) % 24 else hour + 12


def heure(m, text):
    """"dix heures quinze" -> "10h15"; "à 4h" -> "16h" when it is noon."""
    hour = read_number(m.group("hw") or m.group("hd"))
    if hour is None or not 0 <= hour <= 23:
        return None
    before = text[:m.start()]
    if DURATION_BEFORE.search(before):
        return None
    # `word_after` reads "d'avance" whole, so the elision is split off first.
    following = engine.word_after(text, m.end()).split("'")[0].split("\u2019")[0]
    if following in NOT_A_CLOCK_AFTER:
        return None

    period = m.group("period")
    said, hour = hour, stated_hour(hour, period, text, m.start())

    if m.group("half"):
        return f"{hour}h30"
    if m.group("quarter"):
        return f"{hour}h15"
    if m.group("lessquarter"):
        return f"{hour - 1 if hour else 23}h45"
    if m.group("less"):
        minute = read_number(m.group("less"))
        if minute is None or not 1 <= minute <= 59:
            return None
        return f"{hour - 1 if hour else 23}h{60 - minute:02d}"
    if m.group("mm"):
        minute = read_number(m.group("mm"))
        if minute is None or not 0 <= minute <= 59:
            return None
        return f"{hour}h{minute:02d}"
    # Nothing after the hour: a bare one needs a cue of its own. A qualifier is
    # one — "4h du matin" is a time and "trois heures" is a count. The hour as
    # it was said decides, not the one the clock resolved it to.
    if said < 13 and not period and not LEAD_BEFORE.search(before):
        return None
    return f"{hour}h"


def midi(m, _text):
    """"midi et demi" -> "12h30". Bare "midi" stays a word."""
    hour = 12 if m.group("w").lower() == "midi" else 0
    if m.group("half"):
        return f"{hour}h30"
    if m.group("quarter"):
        return f"{hour}h15"
    if m.group("lessquarter"):
        return f"{hour - 1 if hour else 23}h45"
    minute = read_number(m.group("less"))
    if minute is None or not 1 <= minute <= 59:
        return None
    return f"{hour - 1 if hour else 23}h{60 - minute:02d}"


def with_century(short):
    """A two-digit year, pivoted on the clock. 25 is 2025 and 99 is 1999."""
    return 2000 + short if short <= engine.now().year % 100 + 10 else 1900 + short


def short_year(m, text):
    """The two-digit year after the match, or None when it is not one."""
    if engine.word_after(text, m.end()) in NOT_A_YEAR_AFTER:
        return None
    value = read_number(m.group("y2"))
    return value if value is not None and 0 <= value <= 99 else None


def jour_mois(m, text):
    """"le trois décembre" -> "le 3 décembre"; "le 12 mai 25" -> "le 12 mai 2025"."""
    raw = m.group("d").lower()
    if raw in FIRST:
        day, written = 1, "1er"
    else:
        day = read_number(raw)
        if day is None:
            return None
        written = str(day)
    if not 1 <= day <= 31:
        return None
    year = read_year(m.group("y")) if m.group("y") else None
    if m.group("y") and year is None:
        return None
    if m.group("y2"):
        short = short_year(m, text)
        # Not a year, so it belongs to the sentence and is put back as it was.
        if short is None:
            return f"{written} {m.group('mon')} {m.group('y2')}"
        year = with_century(short)
    return f"{written} {m.group('mon')}" + (f" {year}" if year else "")


def jour_du_mois(m, text):
    """"le dix du douze" -> "le 10/12"; "du 3 du 12 2025" -> "du 3/12/2025"."""
    day, month = read_number(m.group("d")), read_number(m.group("m"))
    if day is None or month is None:
        return None
    if not 1 <= day <= 31 or not 1 <= month <= 12:
        return None
    written = f"{m.group('lead')} {day}/{month}"
    if m.group("y"):
        year = read_year(m.group("y"))
        return written + f"/{year}" if year else None
    if m.group("y2"):
        short = short_year(m, text)
        # Written as it was said. A slash date carries no century.
        if short is None:
            return f"{written} {m.group('y2')}"
        return written + f"/{short:02d}"
    return written


def annee_apres_slash(m, text):
    """"Le 3/12 25" -> "Le 3/12/25". The date is written, the year is not."""
    short = short_year(m, text)
    if short is None:
        return None
    return f"{m.group('lead')} {m.group('dm')}/{short:02d}"


# Order is the whole of rule precedence: dates before times, and the longest
# form of a time before its shorter ones.
RULES = [(name, re.compile(pattern, re.I), handler) for name, pattern, handler in [
    ("préposition N du N",
     rf"\b(?P<lead>{BEFORE_DATE})\s+(?P<d>{NUM})\s+du\s+(?P<m>{NUM})\b"
     rf"(?:\s+(?:(?P<y>{YEAR})|(?P<y2>{NUM})))?",
     jour_du_mois),
    ("date en chiffres et son année",
     rf"\b(?P<lead>{BEFORE_DATE})\s+(?P<dm>\d{{1,2}}/\d{{1,2}})\s+(?P<y2>\d{{2}})\b",
     annee_apres_slash),
    ("jour mois",
     rf"\b(?P<d>{engine.alt(FIRST)}|{NUM})\s+(?P<mon>{MONTH})"
     rf"(?:\s+(?:(?P<y>{YEAR})|(?P<y2>{NUM})))?\b",
     jour_mois),
    ("midi ou minuit",
     rf"\b(?P<w>midi|minuit)\s+{TAIL}",
     midi),
    ("heures",
     rf"(?<![\dh]){HOUR}(?:\s+{TAIL})?{PERIOD}?",
     heure),
]]


if __name__ == "__main__":
    engine.main(sys.modules[__name__])
