# Les mots de ponctuation en français.
#
# L'espace fine insécable ( ) fait partie de la marque, pas d'une règle :
# le français en met une avant ? ! ; : et à l'intérieur des guillemets. Écrite
# ici, elle sort toute seule — aucun code ne connaît la typographie.

MARKS = {
    "point d'interrogation": '\u202f?',
    "point d'exclamation": '\u202f!',
    'point-virgule': '\u202f;',
    'point virgule': '\u202f;',
    'virgule': ',',
    'points de suspension': '…',
    # `deux points` n'est pas ici. Mesuré : sur 3 785 dictées, "deux points"
    # apparaît 3 fois et jamais comme une marque — "les deux points suivants",
    # "des deux points en question". Le garde `talked_about` attrape celles-là,
    # mais pas "il a relevé deux points importants", sans déterminant devant.
    # Même refus que `point` tout seul dans `dotted`.
}

# Impératif et infinitif : on dicte "ouvrez" comme "ouvrir".
OPEN = ['ouvre', 'ouvrez', 'ouvrir', 'ouvrant']
CLOSE = ['ferme', 'fermez', 'fermer', 'fermant']
# "ouvrez LES parenthèses" — le déterminant est facultatif et se place entre
# le verbe et le nom. C'est la seule chose que l'anglais n'a pas.
BETWEEN = ['le', 'la', 'les', 'un', 'une', 'des']

PAIRS = (
    {'mark': ('(', ')'), 'names': ['parenthèse', 'parenthèses']},
    # En français les guillemets sont une paire comme les autres : c'est
    # l'anglais qui est irrégulier avec "quote … unquote".
    {'mark': ('«\u202f', '\u202f»'), 'names': ['guillemet', 'guillemets']},
    {'mark': ('[', ']'), 'names': ['crochet', 'crochets']},
    {'mark': ('{', '}'), 'names': ['accolade', 'accolades']},
    {'mark': ('<', '>'), 'names': ['chevron', 'chevrons']},
)
