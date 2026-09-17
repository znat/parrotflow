#!/usr/bin/env python3
"""French spoken numbers as digits: "deux cents euros" -> 200 euros.

Transcript in, rewrite out — plain text, or the JSON envelope when the app sets
`PARROTFLOW_PROTOCOL`. Publishes `count`, how many numbers it wrote.

    - name: numbers_fr
      description: spoken numbers as digits
      command: examples/numbers/fr.py
      returns: json
      tests: { path: examples/numbers/cases-fr.yaml }

    pipeline:
      - transform: numbers_fr

Only the vocabulary and the three rules that differ are here: 70, 80 and 90
are arithmetic (`two_digit="vigesimal"`), `et` joins two halves of a number,
and a bare `cent` or `mille` counts as one. `engine.py` holds the rest.

Score with `./score.py --lang fr`, or `ParrotFlow --eval numbers_fr`.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import engine  # noqa: E402


# No hyphens in these tables: the tokeniser splits on them, so
# "quatre-vingt-dix-sept" arrives as four tokens either way.
GRAMMAR = engine.Grammar(
    code="fr",
    units={
        "zéro": 0, "zero": 0,
        # "une" is the same number and a very common article. It is safe here
        # only because a lone unit below ten stays a word — see
        # `engine.DIGITS_FROM` — so "une question" is never touched.
        "un": 1, "une": 1,
        "deux": 2, "trois": 3, "quatre": 4, "cinq": 5,
        "six": 6, "sept": 7, "huit": 8, "neuf": 9,
    },
    teens={
        "dix": 10, "onze": 11, "douze": 12, "treize": 13,
        "quatorze": 14, "quinze": 15, "seize": 16,
    },
    tens={
        "vingt": 20, "vingts": 20,
        "trente": 30, "quarante": 40, "cinquante": 50, "soixante": 60,
        # Belgium and Switzerland. One table reads either speaker: nobody says
        # both "septante" and "soixante-dix", and nothing upstream knows which.
        "septante": 70, "septantes": 70,
        "octante": 80, "huitante": 80,
        "nonante": 90, "nonantes": 90,
    },
    scales={
        "mille": 1000, "milles": 1000,
        "million": 1000000, "millions": 1000000,
        "milliard": 1000000000, "milliards": 1000000000,
    },
    hundred={"cent", "cents"},
    ordinal_units={
        "premier": 1, "première": 1, "premiere": 1,
        # The form "premier" takes only when it follows a tens word: "vingt et
        # unième" is 21st, and without this it came back as "20 et unième".
        "unième": 1, "unieme": 1,
        "deuxième": 2, "deuxieme": 2,
        "troisième": 3, "troisieme": 3, "quatrième": 4, "quatrieme": 4,
        "cinquième": 5, "cinquieme": 5, "sixième": 6, "sixieme": 6,
        "septième": 7, "septieme": 7, "huitième": 8, "huitieme": 8,
        "neuvième": 9, "neuvieme": 9,
    },
    ordinal_teens={
        "dixième": 10, "dixieme": 10, "onzième": 11, "onzieme": 11,
        "douzième": 12, "douzieme": 12, "treizième": 13, "treizieme": 13,
        "quatorzième": 14, "quatorzieme": 14, "quinzième": 15,
        "quinzieme": 15, "seizième": 16, "seizieme": 16,
    },
    ordinal_tens={
        "vingtième": 20, "vingtieme": 20, "trentième": 30, "trentieme": 30,
        "quarantième": 40, "quarantieme": 40, "cinquantième": 50,
        "cinquantieme": 50, "soixantième": 60, "soixantieme": 60,
        "septantième": 70, "septantieme": 70,
        "octantième": 80, "octantieme": 80, "huitantième": 80,
        "huitantieme": 80, "nonantième": 90, "nonantieme": 90,
    },
    ordinal_scales={"millième": 1000, "millieme": 1000,
                    "millionième": 1000000, "millionieme": 1000000},
    ordinal_hundred={"centième", "centieme"},
    connectors={"et": "and", "virgule": "point"},
    two_digit="vigesimal",
    bare_scale_is_one=True,
    # None. French says "cent", not "un cent", and `un` is already the unit —
    # an article rule here would fire on every "un" in the language.
    article_one=None,
    # "pour cent" and "pour mille" are the percent and per-mille signs. This is
    # what keeps "soixante-quinze pour cent" from becoming "75 pour 100".
    bare_scale_blockers={"pour"},
    percent=(("pour", "cent"),),
    decimal_separator=",",
    # 1er, then 2e, 3e. The feminine "1re" cannot be known from the number, and
    # the masculine is the form that reads acceptably either way.
    ordinal_suffix=lambda value: "er" if value == 1 else "e",
)


if __name__ == "__main__":
    engine.main(GRAMMAR)
