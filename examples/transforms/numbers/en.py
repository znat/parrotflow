#!/usr/bin/env python3
"""English spoken numbers as digits: "two hundred forty-three" -> 243.

    - name: numbers_en
      description: spoken numbers as digits
      command: examples/numbers/en.py
      returns: json
      tests: { path: examples/numbers/cases-en.yaml }

    pipeline:
      - transform: numbers_en
        when: <the regex printed by `en.py --when`>

Only the vocabulary and the three rules that differ are here. Everything else —
where a number begins and ends, years, decimals, ordinals, percent, the
cross-language guard — is `engine.py` beside this file, and so is the note on
adding a language.

English rules, all three of them:

  - **A tens word takes at most one unit.** "forty three" is 43 and nothing
    else follows. That is what stops "ten fifteen" becoming 25.
  - **A bare scale word is not a number.** "hundreds of people" is not 100 of
    people, so `hundred` needs an "a" or a number in front.
  - **"a" stands in for one** before hundred and thousand. Not past that: "a
    million reasons" is a figure of speech, not a figure.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import engine  # noqa: E402


def suffix(value):
    if value % 100 in (11, 12, 13):
        return "th"
    return {1: "st", 2: "nd", 3: "rd"}.get(value % 10, "th")


GRAMMAR = engine.Grammar(
    code="en",
    units={
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    },
    teens={
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19,
    },
    tens={
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    },
    scales={
        "thousand": 1000, "million": 1000000,
        "billion": 1000000000, "trillion": 1000000000000,
    },
    hundred={"hundred"},
    # "second" is deliberately missing. It is a unit of time far more often
    # than an ordinal here, and the collision is not decidable without context:
    # "a thirty second timeout" would become "a 32nd timeout". Leaving it out
    # costs "the twenty second of March" and buys back every spoken duration.
    ordinal_units={
        "first": 1, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
    },
    ordinal_teens={
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13,
        "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17,
        "eighteenth": 18, "nineteenth": 19,
    },
    ordinal_tens={
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50,
        "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
    },
    ordinal_scales={"thousandth": 1000, "millionth": 1000000,
                    "billionth": 1000000000},
    ordinal_hundred={"hundredth"},
    connectors={"and": "and", "point": "point", "oh": "oh"},
    two_digit="additive",
    bare_scale_is_one=False,
    article_one="a",
    # English says "per cent" as two words too, and `cent` is not an English
    # number word anyway, but the list costs nothing and documents the shape.
    bare_scale_blockers={"per"},
    percent=(("percent",), ("per", "cent")),
    decimal_separator=".",
    ordinal_suffix=suffix,
)


if __name__ == "__main__":
    engine.main(GRAMMAR)
