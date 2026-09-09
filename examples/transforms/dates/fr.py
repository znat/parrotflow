#!/usr/bin/env python3
"""Dates et heures dictées, écrites comme elles ont été dites. Transcript on
stdin, rewrite on stdout.

    - name: dates_fr
      description: dictated dates and clock times as digits
      command: examples/dates/fr.py
      returns: json
      tests: examples/dates/fr-cases.yaml

    pipeline:
      - transform: dates_fr
        when: <the regex printed by `fr.py --when`>

"dix heures quinze" -> "10h15". "le trois décembre" -> "le 3 décembre". "le dix
du douze" -> "le 10/12". Publishes `count`, how many spans were rewritten, and
`applied`, the rules that fired.

Self-contained. The word tables below are this file's, and `engine.py` beside
it holds only the loop, the JSON protocol and the `--when` printer. See its
docstring for the contract and for how to add a language.

**Before `numbers`, on words.** Measured on the numbers stage: "trois heures et
demie" and "le trois décembre" come back unchanged from it, while "à dix heures
quinze" becomes "à 10 heures 15" and "le dix du douze" becomes "le 10 du 12".
Once numbers has run the words a date is made of are gone. So this reads them
first, and it also accepts digits.

**No cue, no rewrite.** A rewrite needs `heures`, `midi`, `minuit`, `et
demie`, `et quart`, `moins`, a month name, or the `le N du N` shape. A third of
`fr-cases.yaml` is text that looks like a date and is not. A transform that
rewrites correct text is worse than one that never fires, because it runs on
every transcript and nobody watches it happen.

The judgement calls, each one a case in the set:

- **A bare `H heures` fires at 13 and above, or after à/vers.** "il y a trois
  heures" is a duration, and so is "pendant trois heures"; "vingt heures" is a
  time. A duration marker before the number declines it outright, and so does a
  `de` or an elided `d'` after it — "trois heures de route", "à trois heures
  d'ici". The known miss is a long duration with no marker: "j'ai dormi vingt
  heures" becomes "j'ai dormi 20h".
- **"a" is not "à".** The unaccented verb was in the lead list and turned "il a
  trois heures d'avance" into "il a 3h d'avance". Accented forms only.
- **"midi" and "minuit" stay words on their own.** "midi et demi" does become
  "12h30", because there the half hour is dictated and "12h30" is how it is
  written.
- **"le" stays.** "le 3 décembre" and "le 10/12" are how the date is written in
  French. The English file drops its "the", because "the 3 March" is not
  English.
- **"premier" is written "1er"**, the one ordinal a French date keeps.
- **Years are read up to "deux mille soixante-neuf".** Above that, digits.
  "mille neuf cent quatre-vingt-dix-neuf" is not a year anybody dictates.

Score with `score.py --lang fr` beside this file, or `ParrotFlow --eval
dates_fr`.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import engine  # noqa: E402 — the path above is what makes it importable

# --- les mots ----------------------------------------------------------------

UNITS = {
    "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5,
    "six": 6, "sept": 7, "huit": 8, "neuf": 9,
}
ONES = {
    "zéro": 0, "zero": 0, **UNITS,
    "dix": 10, "onze": 11, "douze": 12, "treize": 13, "quatorze": 14,
    "quinze": 15, "seize": 16,
}
# Belgium and Switzerland live here too: nobody says both "septante" and
# "soixante-dix", so one table reads either speaker.
TENS = {
    "vingt": 20, "vingts": 20, "trente": 30, "quarante": 40,
    "cinquante": 50, "soixante": 60, "septante": 70,
    "octante": 80, "huitante": 80, "nonante": 90,
}
# The one ordinal a date uses. "unième" is also 1 but only ever after a tens
# word, so it is never a day.
FIRST = {"premier", "première", "premiere", "1er"}
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

# "trois heures de route", "24 heures sur 24", "à trois heures d'ici".
NOT_A_CLOCK_AFTER = {"de", "du", "des", "sur", "devant", "d"}

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

# --- lire un nombre dans un fragment -----------------------------------------


def read_number(text):
    """0–99 from words or digits, or None.

    Hyphen and space are the same separator, so "dix-sept" and "dix sept" read
    alike — but the whole form is looked up before it is split, because a table
    may hold either.
    """
    raw = (text or "").strip().lower()
    if raw.isdigit():
        return int(raw)
    joined = re.sub(r"[-\s]+", "-", raw)
    if joined in ONES or joined in TENS:
        return ONES.get(joined, TENS.get(joined))
    parts = joined.split("-")
    if len(parts) == 2 and parts[0] in TENS and parts[1] in UNITS:
        return TENS[parts[0]] + UNITS[parts[1]]
    if len(parts) == 2 and ONES.get(parts[0]) == 10 and parts[1] in UNITS:
        unit = UNITS[parts[1]]
        return 10 + unit if 7 <= unit <= 9 else None
    if len(parts) == 3 and parts[0] in TENS and parts[1] == "et":
        return TENS[parts[0]] + 1 if parts[2] in ("un", "une") else None
    return None


def read_year(text):
    """1000–2999 from a spoken year, or None."""
    raw = re.sub(r"[-\s]+", " ", (text or "").strip().lower())
    if raw.isdigit():
        return int(raw) if 1000 <= int(raw) <= 2999 else None
    if raw.startswith("deux mille"):
        rest = raw[len("deux mille"):].strip()
        if not rest:
            return 2000
        value = read_number(rest)
        return 2000 + value if value is not None else None
    return None


def word_after(text, at):
    """The next word after offset `at`, lowercased, or "" at the end."""
    found = re.match(r"\s*([\w'’-]+)", text[at:])
    return found.group(1).lower() if found else ""


# --- ce que les règles écrivent ----------------------------------------------

def heure(m, text):
    """"dix heures quinze" -> "10h15"; "vingt heures" -> "20h"."""
    hour = read_number(m.group("h"))
    if hour is None or not 0 <= hour <= 23:
        return None
    before = text[:m.start()]
    if DURATION_BEFORE.search(before):
        return None
    # `word_after` reads "d'avance" whole, so the elision is split off first.
    following = word_after(text, m.end()).split("'")[0].split("’")[0]
    if following in NOT_A_CLOCK_AFTER:
        return None

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
    # Nothing after "heures": a bare hour needs its own cue.
    if hour < 13 and not LEAD_BEFORE.search(before):
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


def jour_mois(m, _text):
    """"le trois décembre" -> "le 3 décembre"; "le premier mai" -> "le 1er mai"."""
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
    return f"{written} {m.group('mon')}" + (f" {year}" if year else "")


def jour_du_mois(m, _text):
    """"le dix du douze" -> "le 10/12". The "le" stays: that is the French."""
    day, month = read_number(m.group("d")), read_number(m.group("m"))
    if day is None or month is None:
        return None
    if not 1 <= day <= 31 or not 1 <= month <= 12:
        return None
    return f"{m.group('le')} {day}/{month}"


# Order is the whole of rule precedence: dates before times, and the longest
# form of a time before its shorter ones.
RULES = [(name, re.compile(pattern, re.I), handler) for name, pattern, handler in [
    ("le N du N",
     rf"\b(?P<le>[Ll]e)\s+(?P<d>{NUM})\s+du\s+(?P<m>{NUM})\b",
     jour_du_mois),
    ("jour mois",
     rf"\b(?P<d>{engine.alt(FIRST)}|{NUM})\s+(?P<mon>{MONTH})"
     rf"(?:\s+(?P<y>{YEAR}))?\b",
     jour_mois),
    ("midi ou minuit",
     rf"\b(?P<w>midi|minuit)\s+{TAIL}",
     midi),
    ("heures",
     rf"(?<![\dh])\b(?P<h>{NUM})\s+heures?\b(?:\s+{TAIL})?",
     heure),
]]


def gate_parts():
    """The `when:` regex, in fragments. See `engine.when`.

    "heures", "midi" and "minuit" are cues on their own. Everything else needs
    a cue word beside a number, so the gate is that pair and not the grammar. A
    month name on its own is deliberately not a cue.
    """
    cues = ["à", "vers", "dès", "du", "le"] + MOIS
    tokens = set(ONES) | set(TENS) | FIRST | set(MOIS)
    return [
        r"\b(?:heures?|midi|minuit)\b",
        rf"\b(?:{engine.alt(cues)})\s+(?:{engine.alt(tokens)}|\d{{1,2}})\b",
    ]


if __name__ == "__main__":
    engine.main(sys.modules[__name__])
