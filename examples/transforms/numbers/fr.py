#!/usr/bin/env python3
"""French spoken numbers as digits: "deux cents euros" -> 200 euros.

    - name: numbers_fr
      description: spoken numbers as digits
      command: examples/numbers/fr.py
      returns: json
      tests: { path: examples/numbers/cases-fr.yaml }

    pipeline:
      - transform: numbers_fr
        when: <the regex printed by `fr.py --when`>

Only the vocabulary and the three rules that differ are here. Everything else —
where a number begins and ends, years, decimals, ordinals, percent, the
cross-language guard — is `engine.py` beside this file, and so is the note on
adding a language.

The three, in the order they hurt:

  - **70, 80, 90 are arithmetic.** `soixante-dix` is 60 + 10, `quatre-vingts`
    is 4 × 20, `quatre-vingt-dix-sept` is 4 × 20 + 10 + 7. The additive rule —
    a tens word takes at most one unit — is what stops "ten fifteen" being 25,
    so French could not simply relax it; it gets `two_digit="vigesimal"`.
  - **`et` joins.** `vingt et un`, `soixante et onze`. It is a connector rather
    than vocabulary, so it only ever binds with a number on both sides and
    cannot fire on ordinary French.
  - **Bare scales count.** `cent cinquante` is 150 and `mille` is 1000, where
    English "hundred" alone is not 100.

Hyphens are not in these tables on purpose. The tokeniser splits on them, so
`quatre-vingt-dix-sept` arrives as four tokens and is read by the same path as
the same words spoken with spaces — which is what the decoder actually writes,
and it varies between the two.

`seconde` is left out for the reason `second` is left out of English: it is a
unit of time more often than an ordinal, and "trente secondes" must not become
"30 2èmes".

Percent is written `75%`, with no space. French typography wants a narrow
no-break space there. This does not, deliberately: the transcript is pasted
into terminals and code fields as often as into prose.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import engine  # noqa: E402


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
        # Belgium and Switzerland, where the vigesimal detour does not exist.
        # They live in the same grammar rather than a `fr_BE` of their own
        # because the two vocabularies are disjoint — nobody says both
        # "septante" and "soixante-dix" — so a table holding both reads either
        # speaker without having to know which one is talking. Which is just as
        # well, since nothing upstream knows.
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
