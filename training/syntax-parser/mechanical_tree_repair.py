"""Offline English repair experiment. No spaCy, model calls, or gold annotations.

Rules are fixed before scoring. This module is not a production pipeline stage.
Offsets and token IDs refer to the original input; no reparse after an edit.
"""
from dataclasses import dataclass, asdict
from repair_structures import tokenize, lexical

MODES = ('unchanged', 'text_repeat', 'reparandum', 'tree_exact', 'tree_cued', 'tree_combined')
# Exclude adjectives/adverbs: identical phrases may be intentional emphasis.
SLOT_RELATIONS = {'nsubj', 'csubj', 'obj', 'iobj', 'obl', 'nmod', 'xcomp',
                  'ccomp', 'mark', 'det', 'case', 'aux', 'cop'}
FUNCTION_WORDS = {'i', 'you', 'he', 'she', 'it', 'we', 'they', 'the', 'a', 'an',
                  'this', 'these', 'those', 'my', 'your', 'our', 'their',
                  'because', 'although', 'if', 'which', 'who', 'to', 'of',
                  'in', 'on', 'at', 'for', 'with', 'from', 'by'}


@dataclass(frozen=True)
class Edit:
    start: int
    end: int
    rule: str
    protected_ids: tuple


def valid_tree(words, heads, labels):
    n = len(words)
    if not n or len(heads) != n or len(labels) != n:
        return False
    if any(type(h) is not int or not 0 <= h <= n for h in heads):
        return False
    if heads.count(0) != 1:
        return False
    for i in range(1, n + 1):
        seen = set()
        while i:
            if i in seen:
                return False
            seen.add(i)
            i = heads[i-1]
    return True


def descendants(root, heads):
    found = {root}
    while True:
        extra = {i for i, h in enumerate(heads, 1) if h in found} - found
        if not extra:
            return found
        found.update(extra)


def span_root(ids, heads):
    roots = [i for i in ids if heads[i-1] not in ids]
    return roots[0] if len(roots) == 1 else None


def corresponding(a, b, heads, labels):
    if a is None or b is None:
        return False
    return ((heads[a-1] == b and labels[a-1] == 'reparandum') or
            (heads[a-1] == heads[b-1] != 0 and labels[a-1] == labels[b-1]
             and labels[a-1] in SLOT_RELATIONS))


def repair(text, words, heads, labels, mode='tree_combined'):
    """Return text and provenance; only inference inputs enter this function."""
    if mode not in MODES:
        raise ValueError(mode)
    actual, starts, ends = tokenize(text)
    base = dict(text=text, edits=[], deleted_lexical_ids=[], rejected_conflicts=0)
    if actual != words or not valid_tree(words, heads, labels):
        return dict(base, error='unaligned tokens or invalid tree; unchanged')
    if mode == 'unchanged':
        return base
    n = len(words)
    lower = [w.casefold() for w in words]
    candidates = []
    if mode in ('text_repeat', 'tree_exact', 'tree_combined'):
        for size in range(1, 7):
            for start in range(n - 2*size + 1):
                mid, end = start + size, start + 2*size
                if lower[start:mid] != lower[mid:end] or not all(lexical(w) for w in words[start:end]):
                    continue
                earlier, latest = set(range(start+1, mid+1)), set(range(mid+1, end+1))
                a, b = span_root(earlier, heads), span_root(latest, heads)
                if mode != 'text_repeat':
                    if size == 1 and lower[start] not in FUNCTION_WORDS:
                        continue
                    if not corresponding(a, b, heads, labels):
                        continue
                    # Earlier constituent must not carry other lexical words.
                    if {i for i in descendants(a, heads) if lexical(words[i-1])} != earlier:
                        continue
                    if any(heads[i-1] in earlier for i in latest):
                        continue
                candidates.append(Edit(starts[start], starts[mid], 'exact_repeat', tuple(sorted(latest))))
    if mode in ('tree_cued', 'tree_combined'):
        lex = [i for i in range(1, n+1) if lexical(words[i-1])]
        # Require an explicit correction marker, not bare "I mean" / "rather".
        for pos in range(len(lex)-2):
            cue = lex[pos:pos+3]
            if [lower[i-1] for i in cue] not in (['no', 'i', 'mean'], ['sorry', 'i', 'mean']):
                continue
            if pos == 0 or pos+3 >= len(lex):
                continue
            # Only commas/whitespace inside a cue; never span sentence boundaries.
            if any(lexical(words[i-1]) is False and words[i-1] != ',' for i in range(cue[0], cue[-1]+1)):
                continue
            left_last, right_first = lex[pos-1], lex[pos+3]
            if any(words[i-1] not in {',', ':'} for i in range(left_last+1, cue[0])):
                continue
            if any(words[i-1] not in {',', ':'} for i in range(cue[-1]+1, right_first)):
                continue
            pairs = []
            for a in range(1, cue[0]):
                earlier = {i for i in descendants(a, heads) if lexical(words[i-1])}
                if not earlier or max(earlier) != left_last or len(earlier) > 6:
                    continue
                if earlier != {i for i in range(min(earlier), left_last+1) if lexical(words[i-1])}:
                    continue
                # A fragment containing its own subject may be a whole clause.
                if any(labels[i-1] in {'nsubj', 'csubj'} for i in earlier if i != a):
                    continue
                for b in range(right_first, min(n+1, right_first+6)):
                    if not corresponding(a, b, heads, labels):
                        continue
                    latest = {i for i in descendants(b, heads) if i >= right_first and lexical(words[i-1])}
                    if right_first not in latest or min(latest) != right_first:
                        continue
                    pairs.append((earlier, latest))
            # Ambiguous boundaries are sent back unchanged instead of guessed.
            boundaries = {(min(a), tuple(sorted(b))) for a, b in pairs}
            if len(boundaries) == 1:
                first, protected = next(iter(boundaries))
                candidates.append(Edit(starts[first-1], starts[right_first-1], 'explicit_cue', protected))
    if mode == 'reparandum':
        for a, (b, rel) in enumerate(zip(heads, labels), 1):
            if rel != 'reparandum' or b <= a:
                continue
            ids = descendants(a, heads)
            lex_ids = {i for i in ids if lexical(words[i-1])}
            if not lex_ids or max(lex_ids) >= b:
                continue
            first, last = min(lex_ids), max(lex_ids)
            if lex_ids != {i for i in range(first, last+1) if lexical(words[i-1])}:
                continue
            # This baseline removes lexical subtrees, not correction markers.
            end = starts[last] if last < n else ends[last-1]
            candidates.append(Edit(starts[first-1], end, 'reparandum_subtree', (b,)))
    # Reject overlapping edit candidates and any deletion of a proposed latest span.
    candidates = list(dict.fromkeys(candidates))
    accepted = []
    protected = {i for c in candidates for i in c.protected_ids}
    for c in candidates:
        clashes = any(c.start < d.end and d.start < c.end for d in candidates if d != c)
        touches_latest = any(c.start <= starts[i-1] < c.end for i in protected)
        if clashes or touches_latest:
            base['rejected_conflicts'] += 1
        else:
            accepted.append(c)
    result = text
    for c in sorted(accepted, key=lambda c: c.start, reverse=True):
        result = result[:c.start] + result[c.end:]
    removed = [i for i in range(1, n+1) if lexical(words[i-1]) and
               any(c.start <= starts[i-1] and ends[i-1] <= c.end for c in accepted)]
    return dict(base, text=result, edits=[asdict(c) for c in accepted], deleted_lexical_ids=removed)
