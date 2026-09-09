#!/usr/bin/env python3
"""Spoken numbers as digits: "two hundred forty-three" -> 243. English and
French, no model, no network.

    - name: numbers
      description: spoken numbers as digits
      command: examples/numbers/numbers.py
      returns: json

    pipeline:
      - transform: numbers
        when: <the regex printed by `numbers.py --when`>

Not a substitution table — there are infinitely many numbers, and "forty"
means 40 in "forty-three" and 40,000 in "forty thousand". About seventy words
build every number in a language, so this parses a grammar over that
vocabulary instead of enumerating results.

The grammar is `ENGLISH` and `FRENCH` below: the vocabulary and the three
rules that differ. Everything else is the same in both. What is *not* in the
grammar is the judgement that matters most: a lone number word below
`DIGITS_FROM` stays a word, compounds convert whatever their size. That is why
"à deux, on a dépensé deux cents euros" keeps its `deux` and writes 200, in
exactly the way "just the two of us" already did.

The arithmetic is the easy half. The hard half is knowing where a number
*ends*, because a plain accumulator sums whatever it is handed:

    "let's meet at ten fifteen"     naive: 10 + 15 => 25

Wrong, and wrong in the worst way — it looks like a number someone said. So
every transition is checked instead. A unit or teen may only be followed by a
scale word; a tens word takes at most one unit; scale words must strictly
descend. Anything else ends the number and begins the next one, which makes a
fabricated value impossible: "ten fifteen" is two numbers, and comes out as
"10 15".

**Percent.** A number followed by "percent", "per cent" or "pour cent" is
written `75%`, and the marker is taken with it. Percent also lifts the
below-ten floor: `five%` is never right, so "five percent" is 5%. No space
before the sign in either language. French typography wants a narrow no-break
space there; this writes `75%` in both, deliberately, because that is what was
asked for and because the transcript is pasted into terminals and code fields
as often as into prose.

The reverse is left alone. "pour cent" with no number in front is the
preposition and a hundred — "il paie pour cent euros" — and no number grammar
can tell which was meant, so a scale word right after `pour` (or `per`) is
never read as a number at all. That rule predates percent: it is what kept
"soixante-quinze pour cent" from becoming "75 pour 100".

**Which grammar.** `ctx.language` is the detected one and is tried first, then
the rest of `ctx.languages` — the configured list, comma separated. Detection
alone is not enough: the recogniser needs four words to answer and returns the
fallback below that, so "cent euros" and "vingt et un" would be handed the
English grammar and come back untouched.

That fallback needs a guard, and the case that proved it was "I have 99
cents": English finds nothing to do, French reads `cents` as its word for
hundreds, and a correct sentence came back as "I have 99 100". So a language
the recogniser did not choose has to bring more evidence than a bare scale
word — a unit, a teen or a tens word — whenever the text was long enough to
identify. Below four words nothing can be identified, so the bar comes down
and every configured grammar gets a turn.

Publishes `numbers.language`, the grammar that actually read the numbers (the
detected one when nothing changed — that is the grammar that was asked and
declined, which is the useful answer to "why did this not become a digit"),
and `numbers.count`, how many numbers it wrote.

Run bare and it reads stdin as plain text in English. Score it with `score.py`
beside this file.
"""
import json
import os
import re
import sys

# Below this a lone number word stays a word. "chapter three" reads better
# than "chapter 3", and the floor is also what keeps "one" the pronoun and "a"
# the article out of reach. Compounds convert whatever their size, so
# "twenty-five" is 25 and "one hundred" is 100.
DIGITS_FROM = 10

# Consecutive spoken digits are a code, a phone number or a version — not
# arithmetic — and get concatenated rather than added. Two is enough to mean
# it; the guards in `digit_run` are what make a floor that low safe.
DIGIT_RUN_LENGTH = 2

# `DictationLanguage.minimumWords`: below four words the recogniser's answer is
# a coin toss, so every configured grammar gets a turn instead.
MINIMUM_WORDS = 4

# The Swift pass tokenises on `[\p{L}\p{N}']+`. `[^\W_]` is the same set here —
# letters and digits, no underscore — and the apostrophe is the ASCII one only,
# as it is there.
WORD = re.compile(r"(?:[^\W_]|')+")


def english_suffix(value):
    if value % 100 in (11, 12, 13):
        return "th"
    return {1: "st", 2: "nd", 3: "rd"}.get(value % 10, "th")


class Grammar:
    """The part of reading a spoken number that changes with the language.

    Everything else in this file is machinery, and none of it is English. What
    is English is the vocabulary, how a tens word combines with what follows
    it, whether a bare scale word counts as one of itself, and how a decimal
    point and an ordinal are written.
    """

    def __init__(self, code, units, teens, tens, scales, hundred,
                 ordinal_units, ordinal_teens, ordinal_tens, ordinal_scales,
                 ordinal_hundred, connectors, two_digit, bare_scale_is_one,
                 article_one, bare_scale_blockers, percent, decimal_separator,
                 ordinal_suffix):
        self.code = code
        self.units, self.teens, self.tens = units, teens, tens
        self.scales, self.hundred = scales, hundred
        self.ordinal_units, self.ordinal_teens = ordinal_units, ordinal_teens
        self.ordinal_tens, self.ordinal_scales = ordinal_tens, ordinal_scales
        self.ordinal_hundred = ordinal_hundred
        self.connectors = connectors
        self.two_digit = two_digit
        self.bare_scale_is_one = bare_scale_is_one
        self.article_one = article_one
        self.bare_scale_blockers = bare_scale_blockers
        self.percent = percent
        self.decimal_separator = decimal_separator
        self.ordinal_suffix = ordinal_suffix

    def classify(self, word):
        """`(kind, value), ordinal` — or None for a word that is not a number.

        A kind is one of unit, teen, tens, hundred, scale, and, point, oh.
        """
        if word in self.units:
            return ("unit", self.units[word]), False
        if word in self.teens:
            return ("teen", self.teens[word]), False
        if word in self.tens:
            return ("tens", self.tens[word]), False
        if word in self.hundred:
            return ("hundred", 0), False
        if word in self.scales:
            return ("scale", self.scales[word]), False
        if word in self.ordinal_units:
            return ("unit", self.ordinal_units[word]), True
        if word in self.ordinal_teens:
            return ("teen", self.ordinal_teens[word]), True
        if word in self.ordinal_tens:
            return ("tens", self.ordinal_tens[word]), True
        if word in self.ordinal_hundred:
            return ("hundred", 0), True
        if word in self.ordinal_scales:
            return ("scale", self.ordinal_scales[word]), True
        return None

    def connector(self, word):
        """Words that join two numbers only when a number stands on both sides
        — "two hundred **and** forty", "vingt **et** un". Never a number by
        themselves, which is what keeps them out of ordinary prose.
        """
        kind = self.connectors.get(word)
        return (kind, 0) if kind else None

    @property
    def word_tables(self):
        return (self.units, self.teens, self.tens, self.scales,
                self.ordinal_units, self.ordinal_teens, self.ordinal_tens,
                self.ordinal_scales)


ENGLISH = Grammar(
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
    # "hundreds of people" is not 100 of people.
    bare_scale_is_one=False,
    # "a hundred and fifty" is a number said aloud; "a" anywhere else is an
    # article. Not extended past thousand: "a million reasons" is a figure of
    # speech, not a figure.
    article_one="a",
    bare_scale_blockers={"per"},
    percent=(("percent",), ("per", "cent")),
    decimal_separator=".",
    ordinal_suffix=english_suffix,
)

# French. The three rules that differ, in the order they hurt:
#
#   - **70, 80, 90 are arithmetic.** `soixante-dix` is 60 + 10,
#     `quatre-vingts` is 4 × 20, `quatre-vingt-dix-sept` is 4 × 20 + 10 + 7.
#     English's rule — a tens word takes at most one unit — is what stops "ten
#     fifteen" being 25, so French gets its own, `vigesimal`.
#   - **`et` joins.** `vingt et un`, `soixante et onze`. It is a connector
#     rather than vocabulary, so it only ever binds with a number on both
#     sides and cannot fire on ordinary French.
#   - **Bare scales count.** `cent cinquante` is 150 and `mille` is 1000,
#     where English "hundred" alone is not 100.
#
# Hyphens are not in these tables on purpose. The tokeniser splits on them, so
# `quatre-vingt-dix-sept` arrives as four tokens and is read by the same path
# as the same words spoken with spaces — which is what the decoder actually
# writes, and it varies between the two.
#
# `seconde` is left out for the reason `second` is left out of English: it is a
# unit of time more often than an ordinal, and "trente secondes" must not
# become "30 2èmes".
FRENCH = Grammar(
    code="fr",
    units={
        "zéro": 0, "zero": 0,
        # "une" is the same number and a very common article. It is safe here
        # only because a lone unit below ten stays a word — see `DIGITS_FROM` —
        # so "une question" is never touched.
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
    # "pour cent" and "pour mille" are the percent and per-mille signs.
    bare_scale_blockers={"pour"},
    percent=(("pour", "cent"),),
    decimal_separator=",",
    # 1er, then 2e, 3e. The feminine "1re" cannot be known from the number, and
    # the masculine is the form that reads acceptably either way.
    ordinal_suffix=lambda value: "er" if value == 1 else "e",
)

GRAMMARS = {"en": ENGLISH, "fr": FRENCH}


def grammar_named(code):
    return GRAMMARS.get(code, ENGLISH)


class Token:
    """One word, and how it is attached to the next one.

    `joined_to_next` is "nothing but spaces or hyphens before the next token" —
    punctuation ends a number, so "two, three others" is not 23.
    `hyphen_to_next` is specifically a hyphen, which binds "three" to "inch" in
    "two three-inch bolts" and has to stop the digit run there.
    """

    __slots__ = ("text", "start", "end", "joined_to_next", "hyphen_to_next")

    def __init__(self, text, start, end, joined_to_next, hyphen_to_next):
        self.text, self.start, self.end = text, start, end
        self.joined_to_next, self.hyphen_to_next = joined_to_next, hyphen_to_next


class Item:
    """A number word in a run: what it means, whether it is an ordinal, and
    which token it came from."""

    __slots__ = ("word", "ordinal", "index")

    def __init__(self, word, ordinal, index):
        self.word, self.ordinal, self.index = word, ordinal, index


class Number:
    """One number the parser read out of a run.

    `literal` keeps digits as written, for runs where their order is the point
    and leading zeros must survive: "zero one two" is 012, not 12. `simple` is
    one two-digit group with no hundred and no scale — the shape the year rule
    pairs up. `forced` is written as digits whatever the threshold says;
    `held` is left as words whatever it says. `begin`/`end` are run positions,
    end exclusive.
    """

    __slots__ = ("value", "literal", "fraction", "ordinal", "simple",
                 "forced", "held", "begin", "end")

    def __init__(self, value=0, literal=None, fraction=None, ordinal=False,
                 simple=False, forced=False, held=False, begin=0, end=0):
        self.value, self.literal, self.fraction = value, literal, fraction
        self.ordinal, self.simple = ordinal, simple
        self.forced, self.held = forced, held
        self.begin, self.end = begin, end

    @property
    def words(self):
        return self.end - self.begin


HYPHENS = ("-", "‑")


def tokenize(text):
    matches = list(WORD.finditer(text))
    tokens = []
    for position, match in enumerate(matches):
        joined = hyphen = False
        if position + 1 < len(matches):
            gap = text[match.end():matches[position + 1].start()]
            joined = all(c.isspace() or c in HYPHENS for c in gap)
            hyphen = joined and any(c in HYPHENS for c in gap)
        tokens.append(Token(match.group().lower(), match.start(), match.end(),
                            joined, hyphen))
    return tokens


def runs(tokens, g):
    """Maximal stretches of adjacent number words. Every item in a run is a
    consecutive token, which is what later lets adjacency be tested on run
    positions alone."""
    found = []
    current = []
    for index, token in enumerate(tokens):
        continues = bool(current) and index > 0 and tokens[index - 1].joined_to_next

        # A scale word opening a run, right after a word that makes it a fixed
        # phrase, is not a number: "pour cent" is a percent sign. Only when it
        # *opens* one — "trois pour cent" leaves the three alone but "deux cent
        # trois" is untouched by this.
        if (not current and index > 0
                and tokens[index - 1].text in g.bare_scale_blockers
                and (token.text in g.hundred or token.text in g.scales)):
            continue

        item = None
        classified = g.classify(token.text)
        following = tokens[index + 1] if index + 1 < len(tokens) else None
        if classified:
            item = Item(classified[0], classified[1], index)
        elif (g.article_one and token.text == g.article_one
                and token.joined_to_next and following is not None
                and (following.text in g.hundred
                     or g.scales.get(following.text) == 1000)):
            item = Item(("unit", 1), False, index)
        elif (g.connector(token.text) and continues and token.joined_to_next
                and following is not None and g.classify(following.text)):
            # Number words on both sides, or it is just English: "one and two
            # came back", "the point five people missed".
            item = Item(g.connector(token.text), False, index)

        if item is None:
            if current:
                found.append(current)
                current = []
            continue
        if current and not continues:
            found.append(current)
            current = []
        current.append(item)
    if current:
        found.append(current)
    return found


def parse_two_digit(run, start, g):
    """Below 100: a unit, a teen, or a tens word taking one unit."""
    if start >= len(run):
        return None
    if g.two_digit == "vigesimal":
        return parse_vigesimal(run, start, g)

    item = run[start]
    kind, value = item.word
    if kind in ("unit", "teen"):
        return value, start + 1, item.ordinal
    if kind == "tens":
        if (not item.ordinal and start + 1 < len(run)
                and run[start + 1].word[0] == "unit" and run[start + 1].word[1] > 0):
            return value + run[start + 1].word[1], start + 2, run[start + 1].ordinal
        return value, start + 1, item.ordinal
    return None


def parse_vigesimal(run, start, g):
    """Below 100 in a language that counts in twenties.

    Three shapes English does not have, and they compose:

        soixante-dix            60 + 10          a tens word taking a teen
        quatre-vingts           4 × 20           a unit multiplying a tens
        quatre-vingt-dix-sept   4 × 20 + 10 + 7  both, and a teen taking a unit

    The multiplication is deliberately narrow — only four, only twenty. A
    general "unit times tens" rule would read "deux vingt" as 40, which is not
    French and would fabricate a number out of two ordinary words. Every
    widening here has to be paid for in cases.yaml, because this is the
    function where a wrong answer looks like a right one.
    """
    item = run[start]
    kind, value = item.word
    ordinal = item.ordinal

    if (kind == "unit" and value == 4 and not item.ordinal
            and start + 1 < len(run) and run[start + 1].word == ("tens", 20)
            and not run[start + 1].ordinal):
        base, index = 80, start + 2
    elif kind == "tens":
        base, index = value, start + 1
    elif kind in ("unit", "teen"):
        # "dix-sept" is one number, and arrives as two tokens because the
        # tokeniser splits hyphens. Only seven, eight and nine: "dix un" is not
        # a number, and reading it as one would make 11 out of a sentence that
        # said ten and one.
        if (item.word == ("teen", 10) and not item.ordinal
                and start + 1 < len(run) and run[start + 1].word[0] == "unit"
                and 7 <= run[start + 1].word[1] <= 9):
            return 10 + run[start + 1].word[1], start + 2, run[start + 1].ordinal
        return value, start + 1, item.ordinal
    else:
        return None

    if ordinal:
        return base, index, True

    # "vingt et un", "soixante et onze". The connector only survived into the
    # run with a number on both sides, so it cannot be prose here.
    after = index
    if after < len(run) and run[after].word[0] == "and":
        after += 1
    if after >= len(run):
        return base, index, ordinal

    tail = run[after]
    tail_kind, tail_value = tail.word
    # Only the sixties and eighties carry a teen: 70-79 and 90-99. Adding one
    # to any other tens word would read "trente douze" as 42.
    if tail_kind == "teen" and base in (60, 80):
        total, end = base + tail_value, after + 1
        if (tail_value == 10 and end < len(run) and run[end].word[0] == "unit"
                and 7 <= run[end].word[1] <= 9 and not tail.ordinal):
            total = base + 10 + run[end].word[1]
            ordinal = run[end].ordinal
            end += 1
        else:
            ordinal = tail.ordinal
        return total, end, ordinal
    if tail_kind == "unit" and tail_value > 0:
        return base + tail_value, after + 1, tail.ordinal
    return base, index, ordinal


def parse_hundreds(run, start, g):
    """Below 1000, with the British "and": "two hundred and forty-three"."""
    if start >= len(run):
        return None
    # "cent cinquante" is 150 with nothing in front of the hundred, where
    # English wants "a hundred" — a bare "hundreds of people" must not become a
    # number. Standing in a one here rather than in the vocabulary keeps that
    # difference to a single flag.
    if (g.bare_scale_is_one and run[start].word[0] == "hundred"
            and not run[start].ordinal):
        head = (1, start, False)
    else:
        head = parse_two_digit(run, start, g)
        if head is None:
            return None

    value, end, ordinal = head
    if ordinal or end >= len(run) or run[end].word[0] != "hundred":
        return value, end, ordinal, False

    hundreds = value * 100
    index = end + 1
    if run[end].ordinal:
        return hundreds, index, True, True

    if (index < len(run) and run[index].word[0] == "and"
            and parse_two_digit(run, index + 1, g) is not None):
        index += 1
    tail = parse_two_digit(run, index, g)
    if tail is None:
        return hundreds, index, False, True
    return hundreds + tail[0], tail[1], tail[2], True


def parse_number(run, start, g):
    """One number, ending the moment the words stop describing one."""
    index = start
    total = 0
    last_scale = None            # None means "no scale yet", i.e. Int.max
    ordinal = False
    scaled = False
    seen = False

    while index < len(run):
        kind, value = run[index].word
        # "mille" on its own is a thousand. Same rule as a bare hundred, and
        # the same reason it is a flag: English "thousands of them" is not 1000
        # of them.
        if (g.bare_scale_is_one and kind == "scale" and not run[index].ordinal
                and (last_scale is None or value < last_scale)
                and parse_hundreds(run, index, g) is None):
            total += value
            last_scale = value
            scaled = seen = True
            index += 1
            continue

        group = parse_hundreds(run, index, g)
        if group is None:
            break
        group_value, group_end, group_ordinal, group_scaled = group
        if group_scaled:
            scaled = True

        # A scale word closes the group and opens the next, and they have to
        # descend: "two thousand three thousand" is two numbers.
        if (not group_ordinal and group_end < len(run)
                and run[group_end].word[0] == "scale"
                and (last_scale is None or run[group_end].word[1] < last_scale)):
            scale = run[group_end].word[1]
            total += group_value * scale
            last_scale = scale
            scaled = seen = True
            index = group_end + 1
            if run[group_end].ordinal:
                ordinal = True
                break
            if (index < len(run) and run[index].word[0] == "and"
                    and parse_hundreds(run, index + 1, g) is not None):
                index += 1
            continue

        total += group_value
        ordinal = group_ordinal
        index = group_end
        seen = True
        break

    if not seen:
        return None

    number = Number(value=total, ordinal=ordinal, simple=not scaled,
                    begin=start, end=index)

    # "three point one four" — single digits after the point, which is how a
    # decimal is spoken. Anything else ends the number.
    if not ordinal and index < len(run) and run[index].word[0] == "point":
        scan = index + 1
        fraction = ""
        while scan < len(run):
            kind, value = run[scan].word
            if kind == "unit" and not run[scan].ordinal:
                fraction += str(value)
            elif kind == "oh":
                fraction += "0"
            else:
                break
            scan += 1
        if fraction:
            number.fraction = fraction
            number.simple = False
            number.end = scan
    return number


def digit_run(run, start, tokens):
    """Spoken digits, concatenated rather than added.

    The guards are the whole reason a two-digit floor is safe. A scale word on
    either side means the digits belong to it — "two three hundred" is 2 and
    300, not 23 hundred — and a hyphen on the right means the last digit
    belongs to the word after it, as in "two three-inch bolts".
    """
    if run[start].word[0] != "unit" or run[start].ordinal:
        return None

    digits = str(run[start].word[1])
    end = start + 1
    while end < len(run):
        kind, value = run[end].word
        if kind == "unit" and not run[end].ordinal:
            digits += str(value)
        elif kind == "oh":
            digits += "0"
        else:
            break
        end += 1
    if end - start < DIGIT_RUN_LENGTH:
        return None

    if start > 0 and run[start - 1].word[0] in ("tens", "hundred", "scale", "point"):
        return None
    if end < len(run):
        if run[end].word[0] in ("hundred", "scale", "point"):
            return None
    elif tokens[run[end - 1].index].hyphen_to_next:
        return None

    return Number(literal=digits, forced=True, begin=start, end=end)


def pair_groups(numbers):
    """Settles what numbers standing side by side were meant to be.

    "nineteen eighty-four" parses as 19 then 84 — correctly, since that is all
    the words say. Pairing them back into a year is a separate, narrower rule,
    and the leading group is held to 13-20: that covers 1300-2099, which is
    every year anyone dictates, and it stops short of ten, eleven and twelve,
    where a clock time would be indistinguishable from one.

    Anything still adjacent afterwards is left as words. Two numbers the parser
    could not read as one are a time, a ratio or a hesitation — "eleven
    thirty", "sixty forty split", "nine eleven" — and writing them out
    separately produces "11 30" and "nine 11", which nobody would type.
    Refusing to guess is the one option that cannot make a transcript that was
    already right worse.
    """
    result = []
    index = 0
    while index < len(numbers):
        current = numbers[index]
        if index + 1 < len(numbers):
            following = numbers[index + 1]
            # Standalone pair only. In a longer chain of adjacent groups — "ten
            # fifteen twenty" — a year is not what any two of them are, and
            # taking the middle two produced "10 1520".
            isolated = ((index == 0 or numbers[index - 1].end != current.begin)
                        and (index + 2 >= len(numbers)
                             or numbers[index + 2].begin != following.end))
            if (isolated and current.simple and following.simple
                    and not current.ordinal and not following.ordinal
                    and current.fraction is None and following.fraction is None
                    and following.begin == current.end
                    and 13 <= current.value <= 20
                    and 10 <= following.value <= 99):
                result.append(Number(value=current.value * 100 + following.value,
                                     forced=True, begin=current.begin,
                                     end=following.end))
                index += 2
                continue
        result.append(current)
        index += 1

    for position in range(len(result) - 1):
        if result[position].end != result[position + 1].begin:
            continue
        if result[position].forced or result[position + 1].forced:
            continue
        result[position].held = True
        result[position + 1].held = True
    return result


def percent_marker(tokens, at, g):
    """The token index the percent marker ends at, or None.

    `at` is the number's last token. The marker has to be attached to it with
    nothing but spaces or hyphens, so "seventy five, percent" is two things.
    """
    if not tokens[at].joined_to_next:
        return None
    for phrase in g.percent:
        index = at + 1
        for position, word in enumerate(phrase):
            if index >= len(tokens) or tokens[index].text != word:
                break
            if position + 1 < len(phrase) and not tokens[index].joined_to_next:
                break
            index += 1
        else:
            return index - 1
    return None


def written(number, g):
    """No thousands separators anywhere: a comma reads well in prose and badly
    in the terminals and code fields this app pastes into."""
    if number.literal is not None:
        return number.literal
    if number.fraction is not None:
        return f"{number.value}{g.decimal_separator}{number.fraction}"
    if number.ordinal:
        return f"{number.value}{g.ordinal_suffix(number.value)}"
    return str(number.value)


def convert(run, tokens, g):
    """The replacements one run asks for: (start, end, text) in `tokens`' string."""
    numbers = []
    index = 0
    while index < len(run):
        digits = digit_run(run, index, tokens)
        if digits is not None:
            numbers.append(digits)
            index = digits.end
            continue
        number = parse_number(run, index, g)
        if number is not None and number.end > index:
            numbers.append(number)
            index = number.end
        else:
            index += 1

    replacements = []
    for number in pair_groups(numbers):
        marker = None
        # Not on an ordinal: "the fifth percent" is not a percentage, and
        # "5th%" is not a thing anyone would type.
        if not number.held and not number.ordinal:
            marker = percent_marker(tokens, run[number.end - 1].index, g)
        # Percent lifts the floor: `five%` is never right.
        wanted = not number.held and (
            number.forced or marker is not None or number.fraction is not None
            or number.value >= DIGITS_FROM or number.words >= 2)
        if not wanted:
            continue
        start = tokens[run[number.begin].index].start
        stop = tokens[marker if marker is not None else run[number.end - 1].index].end
        replacements.append(
            (start, stop, written(number, g) + ("%" if marker is not None else "")))
    return replacements


def apply_grammar(text, g):
    """`(text, count)` — the rewrite and how many numbers it wrote."""
    tokens = tokenize(text)
    if not tokens:
        return text, 0

    replacements = []
    for run in runs(tokens, g):
        replacements += convert(run, tokens, g)
    if not replacements:
        return text, 0

    out = text
    for start, stop, digits in sorted(replacements, key=lambda r: -r[0]):
        out = out[:start] + digits + out[stop:]
    return out, len(replacements)


def has_plain_number_word(text, g):
    """Whether the text contains a word this grammar reads as a unit, a teen or
    a tens word — as opposed to only a scale word, which is where the two
    languages collide."""
    for token in tokenize(text):
        classified = g.classify(token.text)
        if classified and classified[0][0] in ("unit", "teen", "tens"):
            return True
    return False


def read(text, language="en", languages=None):
    """`(text, language, count)` — the rewrite, the grammar that read it, and
    how many numbers it wrote.

    The detected language is tried first and the rest of the configured list
    after it, stopping at the one that changes something. When nothing changed
    there is no winner and the detected language is reported.
    """
    languages = [code for code in (languages or []) if code] or [language or "en"]
    fallback = languages[0]
    detected = language if language in languages else fallback

    out, count = apply_grammar(text, grammar_named(detected))
    if out != text:
        return out, detected, count

    identifiable = len(text.split()) >= MINIMUM_WORDS and len(languages) > 1
    for code in languages:
        if code == detected:
            continue
        g = grammar_named(code)
        out, count = apply_grammar(text, g)
        if out == text:
            continue
        if identifiable and not has_plain_number_word(text, g):
            continue
        return out, code, count
    return text, detected, 0


def gate():
    """A regex matching every word any grammar here reads as a number.

    Printed by `--when` and written onto the pipeline step, so the python3
    start is paid only on a transcript that could contain a number. Generated
    rather than typed: a gate that misses a word is a silent miss, and nothing
    would show it happening. `score.py` fails if a case that must change does
    not match this.

    Connectors ("and", "point", "et", "virgule") and the article "a" are left
    out. None of them makes a number without one of these words beside it.
    Percent markers are left out for the same reason: "percent" alone writes
    nothing. `(?i)` is stated rather than assumed — the pipeline compiles a
    `when:` pattern case-insensitively already, but the regex is also read by
    `score.py` and by whoever pastes it somewhere else.
    """
    words = set()
    for g in GRAMMARS.values():
        for table in g.word_tables:
            words |= set(table)
        words |= g.hundred | g.ordinal_hundred
    ordered = sorted(words, key=lambda word: (-len(word), word))
    return r"(?i)\b(?:" + "|".join(ordered) + r")\b"


def main():
    if "--when" in sys.argv[1:]:
        print(gate())
        return

    # ParrotFlow sets PARROTFLOW_PROTOCOL=json when the transform declares
    # `returns: json`, and then stdin is the envelope. Unset is the plain path,
    # which is what a bare `echo … | numbers.py` gets.
    structured = os.environ.get("PARROTFLOW_PROTOCOL") == "json"
    raw = sys.stdin.read()
    envelope = json.loads(raw) if structured else {"text": raw}
    text = envelope["text"]
    ctx = envelope.get("ctx") or {}

    try:
        language = ctx.get("language") or "en"
        # The configured list, comma separated — the scope holds scalars. It is
        # what the multi-language rule needs and detection cannot give.
        configured = [code.strip().lower()
                      for code in (ctx.get("languages") or "").split(",")
                      if code.strip()]
        out, read_by, count = read(text, language, configured or [language])
    except Exception:
        # Fail open — never drop the whole transcript because a guard threw.
        out, read_by, count = text, ctx.get("language") or "en", 0

    if not structured:
        sys.stdout.write(out)
        return
    print(json.dumps({"text": out, "vars": {"language": read_by, "count": count}}))


if __name__ == "__main__":
    main()
