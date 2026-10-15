#!/usr/bin/env python3
"""Spoken PR and issue numbers as links, in English and French.

    PR 412                        -> [#412](.../pull/412)
    PR 26, 34                     -> [#2634]   a number said in two halves
    PR twenty-six thirty-four     -> [#2634]   the number stages leave these
    la PR vingt-six trente-quatre -> la [#2634]   as words
    PRs 26 and 74                 -> [#26] and [#74]
    les PR 26, 27, 28 et 29       -> les [#26], [#27], [#28] et [#29]
    issues 45 and 46              -> two issue links

The repository URL is the first argument:

    command: built-in/github_refs/github_refs.py https://github.com/OWNER/REPO

Runs after `numbers_en` / `numbers_fr`. "and", "or", "et", "ou" and "&" split a
list, and so does a comma after a plural. French marks the plural on the
article ("les PR"). Inside each part, two-digit halves are glued onto a one- or
two-digit start, so "PR 412, 300 tests" keeps its count. A plural with one
number is not a reference ("2 issues 3 days ago").

`\\s*` and not `\\s+` after "PR": the decoder writes "PR123" with no space
when you say "P R one two three". Measured, and it is the most common
spelling of the lot.
"""
import re
import sys

# What may sit between "PR" and its number.
REF_WORDS = ["number", "nr", "no", "num", "hash", "numéro"]
ARTICLES = ["les", "des", "ces", "mes", "tes", "ses", "nos", "vos", "leurs"]

SEP = r"(?:,\s*(?:and|or|et|ou)\s+|,\s*|\s+(?:and|or|et|ou|&)\s+|\s+)"
HEAD = (
    r"(?:(?P<article>\b(?i:" + "|".join(ARTICLES) + r")\s+))?"
    r"\b(?:(?P<pull>(?i:pull request)|PR|P\.R\.|P R)(?P<pulls>s?)\s*"
    r"|(?P<issue>(?i:issue))(?P<issues>s?)\s+)"
    r"(?:(?i:" + "|".join(REF_WORDS) + r")\s+)?"
)
PATTERN = re.compile(HEAD + r"(?P<run>#?\d+(?:" + SEP + r"#?\d+)*)\b")

UNITS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9,
    "un": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5,
    "sept": 7, "huit": 8, "neuf": 9,
}
TEENS = {
    "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
    "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    "dix": 10, "onze": 11, "douze": 12, "treize": 13, "quatorze": 14,
    "quinze": 15, "seize": 16, "dix-sept": 17, "dix-huit": 18, "dix-neuf": 19,
}
TENS = {
    "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
    "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    "vingt": 20, "trente": 30, "quarante": 40, "cinquante": 50,
    "soixante": 60, "quatre-vingt": 80, "quatre-vingts": 80,
}
ZEROS = ["oh", "zero", "zéro"]


def alternatives(table):
    keys = sorted(table, key=len, reverse=True)
    return "|".join(k.replace("-", r"[\s-]") for k in keys)


# A lone unit is not converted: "a PR one day". The "et" of "vingt et un" and
# "soixante et onze" belongs to the number, not the list.
HALF = (
    r"(?i:(?:" + alternatives(TENS) + r")"
    r"(?:[\s-]+(?:et[\s-]+)?(?:" + alternatives(TEENS) + r"|" + alternatives(UNITS) + r"))?"
    r"|(?:" + alternatives(TEENS) + r")"
    r"|(?:" + "|".join(ZEROS) + r")[\s-]+(?:" + alternatives(UNITS) + r"))\b"
)
SPOKEN = re.compile(
    HEAD + r"(?P<run>(?:#?\d+|" + HALF + r")(?:" + SEP + r"(?:#?\d+|" + HALF + r"))*)\b"
)
ITEM = re.compile(r"(?P<sep>" + SEP + r")?#?(?P<num>\d+)")


def half(match):
    text = re.sub(r"[\s-]+", "-", match.group(0).lower())
    head, _, rest = text.partition("-")
    if head in ZEROS:
        return f"0{UNITS[rest]}"
    for tens in sorted(TENS, key=len, reverse=True):
        if text == tens or text.startswith(tens + "-"):
            rest = text[len(tens):].strip("-").removeprefix("et-")
            return str(TENS[tens] + (TEENS.get(rest) or UNITS.get(rest) or 0))
    return str(TEENS[text])


def spell(match):
    run = match.group("run")
    return match.group(0)[: match.start("run") - match.start()] + re.sub(HALF, half, run)


def rewriter(repo):
    def link(kind, number):
        return f"[#{number}]({repo}/{kind}/{number})"

    def rewrite(match):
        kind = "pull" if match.group("pull") else "issues"
        plural = bool(match.group("pulls") or match.group("issues") or match.group("article"))
        run = match.group("run")

        parts = []
        for item in ITEM.finditer(run):
            sep = item.group("sep") or ""
            if not parts or re.search(r"[a-z&]", sep):
                parts.append([item])
            elif plural and "," in sep:
                # "PRs 2604, 300 tests failed": a count, not a third reference.
                if len(item.group("num")) != len(parts[-1][0].group("num")):
                    break
                parts.append([item])
            else:
                parts[-1].append(item)

        links, end = "", 0
        for part in parts:
            glued = part[:1]
            if len(part[0].group("num")) <= 2:
                for item in part[1:]:
                    if len(item.group("num")) != 2:
                        break
                    glued.append(item)
            links += (part[0].group("sep") or "") + link(kind, "".join(i.group("num") for i in glued))
            end = glued[-1].end()
            if len(glued) < len(part):
                break
        if plural and links.count("](") < 2:
            return match.group(0)
        return (match.group("article") or "") + links + run[end:]

    return rewrite


def linker(repo):
    rewrite = rewriter(repo)

    def replace(match):
        spelled = spell(match)
        linked = PATTERN.sub(rewrite, spelled)
        return linked if linked != spelled else match.group(0)

    return replace


def main():
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        sys.exit("github_refs: pass the repository URL, e.g. "
                 "github_refs.py https://github.com/OWNER/REPO")
    repo = sys.argv[1].strip().rstrip("/")
    sys.stdout.write(SPOKEN.sub(linker(repo), sys.stdin.read()))


if __name__ == "__main__":
    main()
