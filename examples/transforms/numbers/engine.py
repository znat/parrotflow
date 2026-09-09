"""Reading spoken numbers, minus the language. Imported by `en.py` and `fr.py`.

Nothing here names a language. What a language brings is a `Grammar`: the word
tables, how a tens word combines with what follows it, whether a bare scale
word counts as one of itself, the article that stands in for one, how a decimal
point and an ordinal are written, and the words that mark a percentage.

Not a substitution table — there are infinitely many numbers, and "forty" means
40 in "forty-three" and 40,000 in "forty thousand". About seventy words build
every number in a language, so this parses a grammar over that vocabulary
instead of enumerating results.

What is *not* in the grammar is the judgement that matters most: a lone number
word below `DIGITS_FROM` stays a word, compounds convert whatever their size.
That is why "on a dépensé deux cents euros" keeps its `deux` and writes 200, in
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

**Percent.** A number followed by one of the grammar's percent markers is
written `75%`, and the marker is taken with it. Percent also lifts the
below-ten floor: `five%` is never right, so "five percent" is 5%. Never on an
ordinal. The reverse is left alone: a scale word right after one of
`bare_scale_blockers` is never read as a number, so "pour cent" with no number
in front stays as heard.

**One script per language, all of them on every transcript.** The steps are not
gated on `language ==`, because the language of a transcript does not decide
which numbers are in it: "on a mergé la pull request avec vingt et un commits"
is French with English in it, and "I have 99 cents" is English with a French
word in it.

So each script runs, and each carries the guard that keeps the second one
honest. When the transcript is four words or more — the length below which
language detection is a coin toss — and `ctx.language` is not this script's
language, a number is only written if its own words include a unit, a teen or a
tens word of this grammar. A bare scale word is not enough. That is the "99
cents" rule: English finds nothing to do, French reads `cents` as its word for
hundreds, and a correct sentence came back as "I have 99 100".

Below four words the bar comes down and every grammar tries, because otherwise
"cent euros" and "vingt et un" — two of the commonest things anyone dictates —
would come back untouched.

Each script publishes `count`, how many numbers it wrote, under its own
transform name.

## Adding a language

Copy a language file and edit its tables. That is the whole job.

    cd examples/transforms/numbers
    cp fr.py es.py                    # then edit GRAMMAR: the word tables,
                                      # two_digit, bare_scale_is_one,
                                      # article_one, percent, the suffixes
    cp cases-fr.yaml cases-es.yaml    # `transform: numbers_es` at the top
    ./es.py --when                    # the regex for the pipeline step
    ./score.py                        # scores every language file it finds

Then two entries in `config.yaml`:

    transforms:
      - name: numbers_es
        description: spoken numbers as digits
        command: examples/numbers/es.py
        returns: json
        tests: { path: examples/numbers/cases-es.yaml }

    pipeline:
      - transform: numbers_es
        when: /<what `es.py --when` printed>/

Nothing in this file changes. If a language needs a rule that is not here —
German fuses `einundzwanzig` into one token in reversed order, which breaks
tokenising before a grammar is ever consulted — that is a change to the engine
and it needs its own cases.

## Scoring

    ./score.py                                  # every language, from the tree
    ./score.py --text "cent euros" --lang fr    # one line
    ParrotFlow --eval numbers_en                # the installed copy, per language
    ParrotFlow --eval numbers_fr
    scripts/check-pipeline.sh                   # detection, the guard and the order
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
# a coin toss, so no grammar is held to the cross-language guard.
MINIMUM_WORDS = 4

# The Swift pass this replaces tokenised on `[\p{L}\p{N}']+`. `[^\W_]` is the
# same set here — letters and digits, no underscore — and the apostrophe is the
# ASCII one only, as it was there.
WORD = re.compile(r"(?:[^\W_]|')+")

HYPHENS = ("-", "‑")


class Grammar:
    """Everything about reading a number that changes with the language.

    `two_digit` is "additive" (a tens word takes at most one unit) or
    "vigesimal" (see `parse_vigesimal`). `bare_scale_is_one` says whether a
    scale word standing alone means one of itself. `article_one` is the word
    that stands in for one before a scale word, or None. `percent` is a tuple
    of word tuples. `bare_scale_blockers` are the words after which a scale
    word is never a number.
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
    def every_word(self):
        """Every word this grammar reads as a number, for `--when`."""
        words = set(self.hundred) | set(self.ordinal_hundred)
        for table in (self.units, self.teens, self.tens, self.scales,
                      self.ordinal_units, self.ordinal_teens,
                      self.ordinal_tens, self.ordinal_scales):
            words |= set(table)
        return words


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
            # Number words on both sides, or it is just prose: "one and two
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

    Three shapes the additive rule does not have, and they compose:

        a tens word taking a teen           60 + 10
        four multiplying a twenty          4 × 20
        both at once, and a teen plus one  4 × 20 + 10 + 7

    The multiplication is deliberately narrow — only four, only twenty. A
    general "unit times tens" rule would read "deux vingt" as 40, which is not
    French and would fabricate a number out of two ordinary words. Every
    widening here has to be paid for in the language's case file, because this
    is the function where a wrong answer looks like a right one.
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
    last_scale = None            # None means "no scale yet"
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


def has_plain_word(run, number):
    """Whether the number's own words include a unit, a teen or a tens word.

    The cross-language guard. A bare scale word is not enough evidence that
    this grammar is the right one to read the sentence: `cents` is French for
    hundreds and English for money, and "I have 99 cents" came back as "I have
    99 100". Asked of the number's own span rather than of the whole text, so
    an unrelated number word elsewhere in the sentence cannot vouch for it.
    """
    return any(run[position].word[0] in ("unit", "teen", "tens")
               for position in range(number.begin, number.end))


def convert(run, tokens, g, guarded):
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
        if guarded and not has_plain_word(run, number):
            continue
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


def apply_grammar(text, g, guarded=False):
    """`(text, count)` — the rewrite and how many numbers it wrote."""
    tokens = tokenize(text)
    if not tokens:
        return text, 0

    replacements = []
    for run in runs(tokens, g):
        replacements += convert(run, tokens, g, guarded)
    if not replacements:
        return text, 0

    out = text
    for start, stop, digits in sorted(replacements, key=lambda r: -r[0]):
        out = out[:start] + digits + out[stop:]
    return out, len(replacements)


def read(text, g, language=None):
    """`(text, count)`, with the cross-language guard applied when it applies.

    `language` is `ctx.language`, the language the pipeline detected. Below
    `MINIMUM_WORDS` it decides nothing and the guard is off.
    """
    guarded = ((language or g.code) != g.code
               and len(text.split()) >= MINIMUM_WORDS)
    return apply_grammar(text, g, guarded=guarded)


def gate(g):
    """A regex matching every word this grammar reads as a number.

    Printed by `--when` and written onto the pipeline step, so the python3
    start is paid only on a transcript that could contain a number. Generated
    rather than typed: a gate that misses a word is a silent miss, and nothing
    would show it happening. `score.py` fails if a case that must change does
    not match it.

    Connectors and the article are left out. Neither makes a number without one
    of these words beside it. Percent markers are left out for the same reason:
    "percent" alone writes nothing. `(?i)` is stated rather than assumed — the
    pipeline compiles a `when:` pattern case-insensitively already, but the
    regex is also read by `score.py` and by whoever pastes it somewhere else.
    """
    ordered = sorted(g.every_word, key=lambda word: (-len(word), word))
    return r"(?i)\b(?:" + "|".join(ordered) + r")\b"


def main(g):
    """The whole entry point. A language file is a `Grammar` and this call."""
    if "--when" in sys.argv[1:]:
        print(gate(g))
        return

    # ParrotFlow sets PARROTFLOW_PROTOCOL=json when the transform declares
    # `returns: json`, and then stdin is the envelope. Unset is the plain path,
    # which is what a bare `echo … | en.py` gets.
    structured = os.environ.get("PARROTFLOW_PROTOCOL") == "json"
    raw = sys.stdin.read()
    envelope = json.loads(raw) if structured else {"text": raw}
    text = envelope["text"]
    ctx = envelope.get("ctx") or {}

    try:
        out, count = read(text, g, ctx.get("language"))
    except Exception:
        # Fail open — never drop the whole transcript because a guard threw.
        out, count = text, 0

    if not structured:
        sys.stdout.write(out)
        return
    print(json.dumps({"text": out, "vars": {"count": count}}))
