#!/usr/bin/env python3
"""Sommes d'argent dictées, écrites avec le symbole.

"20 euros" -> "20 €". "25 euros 50" -> "25,50 €". Transcript
in, rewrite out. Publishes `count`, the amounts it rewrote, and `applied`, the
rules that fired.

    - name: money_fr
      description: dictated amounts of money with the currency symbol
      command: examples/money/fr.py
      returns: json
      tests: examples/money/cases-fr.yaml

    pipeline:
      - transform: money_fr     # below numbers_fr, which writes the digits

Digits in, symbol out. It reads no number words: `numbers_fr` above it has a
currency word in its `currency` set, so it writes even "cinq euros" as
"5 euros" before this stage sees it.

No number, no rewrite: "la zone euro" and "le dollar est fort" are left as they
are. A scale word between the digits and the currency declines — "2,5 millions
d'euros" is already how it is written. French agrees its numbers, so there is
no singular-versus-plural question the way English has one. `engine.py` holds the loop, the JSON
protocol and the cross-language guard, which matters here: `euros` and
`dollars` are the same word in English.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import engine  # noqa: E402 — the path above is what makes it importable

CODE = "fr"

# --- les mots ----------------------------------------------------------------


# The symbol goes after in French, with a space.
CURRENCIES = {
    "euro": "€", "euros": "€",
    "dollar": "$", "dollars": "$",
}
CENTIMES = ("centimes", "centime", "cents", "cent")

# A noun right after a bare tail says the tail was counting, not centimes:
# "20 euros 3 fois".
STOP_AFTER = {
    "fois", "personnes", "gens", "heures", "jours", "semaines", "mois",
    "ans", "minutes", "secondes", "pièces", "pieces", "chacun", "chacune",
    "articles", "exemplaires", "parts", "pour",
}

# --- les motifs --------------------------------------------------------------

# The amount `numbers_fr` wrote: digits of any size. The lookbehind leaves an
# amount something already wrote alone, and its hyphen keeps this off the
# second half of a number nothing converted.
AMOUNT = r"(?<![$€\d.,\-‑])\d+(?:,\d+)?"
CUR = engine.alt(CURRENCIES)
# "deux millions d'euros" becomes "2000000 d'euros": the elision is left over
# from a noun that is now a number, and goes with it.
OF = r"(?:d['’]\s*)?"


def symbol(word):
    return CURRENCIES[word.lower()]


# --- ce que les règles écrivent ----------------------------------------------

def avec_centimes(m, text):
    """"vingt euros et cinquante centimes" -> "20,50 €"."""
    whole, word = m.group("n"), m.group("cur")
    written = whole
    cents = int(m.group("c"))
    if not 0 <= cents <= 99 or "," in written:
        return None
    return f"{written},{cents:02d} {symbol(word)}"


def centimes_sans_le_mot(m, text):
    """"vingt-cinq euros cinquante" -> "25,50 €". Le mot n'a pas été dit.

    Only a tail of ten and over. "20 euros 3" is a count that ran on, and a
    tail under ten is never dictated without the centimes word.
    """
    whole, word = m.group("n"), m.group("cur")
    written = whole
    cents = int(m.group("c"))
    if not 10 <= cents <= 99 or "," in written:
        return None
    if engine.word_after(text, m.end()) in STOP_AFTER:
        return None
    return f"{written},{cents:02d} {symbol(word)}"


def somme(m, text):
    """"vingt euros" -> "20 €"."""
    whole, word = m.group("n"), m.group("cur")
    return f"{whole} {symbol(word)}"


# L'ordre fait toute la précédence : la forme la plus longue d'abord, pour que
# les centimes ne restent pas derrière en nombre isolé.
RULES = [(name, re.compile(pattern, re.I), handler) for name, pattern, handler in [
    ("somme et centimes",
     rf"\b(?P<n>{AMOUNT})\s+{OF}(?P<cur>{CUR})\s+(?:et\s+)?(?P<c>\d{{1,2}}"
     rf")\s+(?:{engine.alt(CENTIMES)})\b",
     avec_centimes),
    ("somme et centimes sans le mot",
     rf"\b(?P<n>{AMOUNT})\s+{OF}(?P<cur>{CUR})\s+(?P<c>\d{{1,2}})\b(?![.,]\d)",
     centimes_sans_le_mot),
    ("somme",
     rf"\b(?P<n>{AMOUNT})\s+{OF}(?P<cur>{CUR})\b",
     somme),
]]


if __name__ == "__main__":
    engine.main(sys.modules[__name__])
