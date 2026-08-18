# The punctuation words for English. One file per language, named by the
# language code; the script loads the one matching `ctx.language` and does
# nothing at all if there is none.
#
# A mark is written verbatim, so whatever spacing a language wants lives in the
# string rather than in a rule. English wants none — see fr.py, which does.

MARKS = {
    'question mark': '?',
    'exclamation point': '!',
    'comma': ',',
    'colon': ':',
    # Three spellings: the decoder picks one and you do not get a say.
    'semicolon': ';',
    'semi colon': ';',
    'semi-colon': ';',
    # One character, not three dots, so a later stage reads it as one sentence
    # end rather than three. "dot dot dot" belongs here and not in `dotted`,
    # which runs later and would make "dot.dot" of it.
    'ellipsis': '…',
    'dot dot dot': '…',
    # No rule for "period" or "full stop": the bus-stop and emphatic-idiom
    # senses win. Same call `dotted` makes on bare "point".
}

# The verbs that open and close a pair. The decoder glues and camel-cases a
# pair it thinks it knows ("openParen") and writes "closed" for "close", so no
# space is required and both endings are accepted.
OPEN = ['open', 'opened', 'opening']
CLOSE = ['close', 'closed', 'closing']
# Nothing between the verb and the noun in English. French has "les".
BETWEEN = []

PAIRS = (
    {'mark': ('[', ']'), 'names': ['bracket', 'brackets', 'square bracket', 'square brackets']},
    {'mark': ('(', ')'), 'names': ['paren', 'parens', 'parenthesis', 'parentheses', 'parent', 'parents']},
    {'mark': ('{', '}'), 'names': ['curly bracket', 'curly brackets', 'brace', 'braces']},
    {'mark': ('<', '>'), 'names': ['angle bracket', 'angle brackets']},
    {'mark': ('"', '"'), 'open': ['quote'], 'close': ['unquote']},
)
