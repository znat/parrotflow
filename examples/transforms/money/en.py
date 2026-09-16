#!/usr/bin/env python3
"""English amounts of money, written with the symbol.

"twenty dollars" -> "$20". "twenty five euros fifty" -> "€25.50". Transcript
in, rewrite out. Publishes `count`, how many amounts it rewrote, and `applied`,
the rules that fired.

    - name: money_en
      description: dictated amounts of money with the currency symbol
      command: examples/money/en.py
      returns: json
      tests: examples/money/cases-en.yaml

    pipeline:
      - transform: money_en     # below numbers_en, which writes the digits

Digits in, symbol out. It reads no number words: `numbers_en` above it has a
currency word in its `currency` set, so it writes even "five dollars" as
"5 dollars" before this stage sees it.

No number, no rewrite: the currency word alone is a noun, so "the dollar is
strong" and "dollar sign" are left as they are. A singular "dollar" with a
noun behind it is an adjective, which is what keeps "a 20 dollar bill" whole.
`engine.py` beside this file holds the loop, the JSON protocol and the
cross-language guard, and says how to add a language.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import engine  # noqa: E402 — the path above is what makes it importable

CODE = "en"

# --- the words ---------------------------------------------------------------

# The symbol goes in front in English, with no space.
CURRENCIES = {
    "dollar": "$", "dollars": "$",
    "euro": "€", "euros": "€",
    # Slang, and only this one. Counted over 1713 archived dictations: 2 say
    # "bucks", none say "quid" or "grand". `USD` is deliberately absent — a
    # code is already unambiguous, and "$200" loses what the speaker chose.
    "buck": "$", "bucks": "$",
}
SINGULAR = {"dollar", "euro", "buck"}
CENTS = ("cents", "cent")

# What a scale word after the digits is allowed to be. "2.5 million dollars"
# keeps the word: "$2500000" is not what was said and not how it is written.
SCALES = ("thousand", "million", "billion", "trillion")

# A noun right after a bare tail says the tail was counting, not cents:
# "20 dollars 3 times".
STOP_AFTER = {
    "times", "people", "person", "each", "apiece", "pieces", "items",
    "units", "hours", "days", "weeks", "months", "years", "minutes",
    "percent", "kids", "men", "women", "shares", "copies",
}

# --- the patterns ------------------------------------------------------------

# The amount `numbers_en` wrote: digits of any size. The lookbehind leaves
# "$20" and "20.50" alone once something already wrote them, and the hyphen in
# it keeps this off the second half of a number nothing converted.
AMOUNT = r"(?<![$€\d.,\-‑])\d+(?:\.\d+)?"
CUR = engine.alt(CURRENCIES)
SCALE = engine.alt(SCALES)


def symbol(word):
    return CURRENCIES[word.lower()]


# Nothing after the currency word but the end of a clause. That is what tells
# an amount from a currency word used as an adjective: "sixty euro." is a
# price, "a 20 dollar bill" is a noun phrase.
CLAUSE_END = re.compile(r"\s*(?:[.,;:!?)\]]|$)")


def singular_ok(m, text, tail=False):
    """Whether a singular currency word here is an amount.

    Plural always is. Singular is when the amount is one ("the fee is one
    dollar"), when cents follow it ("sixty euro and seventy cents" — heard,
    2026-09-16), or when the clause ends there ("it costs sixty euro.").

    English uses a singular currency word both ways and only the noun after it
    says which — "a 20 dollar bill", "a 30 dollar per hour rate". There is no
    tagger in this stage, so the rule is the other way round: a singular word
    is an amount when nothing follows it.
    """
    if m.group("cur").lower() not in SINGULAR:
        return True
    if m.group("n") == "1" or tail:
        return True
    return bool(CLAUSE_END.match(text[m.end():]))


# --- what the rules write ----------------------------------------------------

def with_cents(m, text):
    """"twenty dollars and fifty cents" -> "$20.50"."""
    whole, word = m.group("n"), m.group("cur")
    if not singular_ok(m, text, tail=True):
        return None
    written = whole
    cents = int(m.group("c"))
    if not 0 <= cents <= 99 or "." in written:
        return None
    return f"{symbol(word)}{written}.{cents:02d}"


def bare_cents_tail(m, text):
    """"twenty five euros fifty" -> "€25.50". The cents word was not said.

    Only a tail of ten and over. "20 dollars 3" is a count that ran on, and a
    tail under ten is never dictated without "oh" or the cents word.
    """
    whole, word = m.group("n"), m.group("cur")
    if not singular_ok(m, text, tail=True):
        return None
    written = whole
    cents = int(m.group("c"))
    if not 10 <= cents <= 99 or "." in written:
        return None
    if engine.word_after(text, m.end()) in STOP_AFTER:
        return None
    return f"{symbol(word)}{written}.{cents:02d}"


def with_scale(m, text):
    """"2.5 million dollars" -> "$2.5 million". The scale word stays a word."""
    whole, word = m.group("n"), m.group("cur")
    if not singular_ok(m, text):
        return None
    return f"{symbol(word)}{whole} {m.group('scale').lower()}"


def plain(m, text):
    """"twenty dollars" -> "$20"."""
    whole, word = m.group("n"), m.group("cur")
    if not singular_ok(m, text):
        return None
    return f"{symbol(word)}{whole}"


# Order is the whole of rule precedence: the longest form of an amount before
# its shorter ones, so the cents never get left behind as a stray number.
RULES = [(name, re.compile(pattern, re.I), handler) for name, pattern, handler in [
    ("amount and cents",
     rf"\b(?P<n>{AMOUNT})\s+(?P<cur>{CUR})\s+(?:and\s+)?(?P<c>\d{{1,2}}"
     rf")\s+(?:{engine.alt(CENTS)})\b",
     with_cents),
    ("amount with a scale word",
     rf"\b(?P<n>{AMOUNT})\s+(?P<scale>{SCALE})\s+(?P<cur>{CUR})\b",
     with_scale),
    ("amount and a bare tail",
     rf"\b(?P<n>{AMOUNT})\s+(?P<cur>{CUR})\s+(?P<c>\d{{1,2}})\b(?![.,]\d)",
     bare_cents_tail),
    ("amount",
     rf"\b(?P<n>{AMOUNT})\s+(?P<cur>{CUR})\b",
     plain),
]]


if __name__ == "__main__":
    engine.main(sys.modules[__name__])
