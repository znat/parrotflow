"""Validate weak local repair drafts and score lexical subtree recovery.

Structural validity is not semantic correctness or verified gold. Dependency IDs
are 1-based; prediction arrays contain one entry per word, with 0 as ROOT.
Punctuation/cue cleanup is deliberately outside the structural recovery score.
"""
import argparse
import json
import re
from collections import Counter
from pathlib import Path

from data import RELATIONS

TOKEN_PATTERN = re.compile(r"\w+(?:['’]\w+)*|[^\w\s]")


def tokenize(text):
    matches = list(TOKEN_PATTERN.finditer(text))
    return ([m.group() for m in matches], [m.start() for m in matches],
            [m.end() for m in matches])


def lexical(word):
    return any(c.isalnum() for c in word)


def _integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _span(span, text, name, errors, require_text=True):
    if not isinstance(span, dict):
        errors.append(f"{name}: expected span object")
        return None
    start, end = span.get('start'), span.get('end')
    if not (_integer(start) and _integer(end) and 0 <= start < end <= len(text)):
        errors.append(f"{name}: invalid half-open bounds")
        return None
    if require_text and span.get('text') != text[start:end]:
        errors.append(f"{name}: text does not equal exact substring")
    return start, end


def _overlap(a, b):
    return a[0] < b[1] and b[0] < a[1]


def validate_record(record):
    """Return useful errors; [] establishes structural validity only."""
    errors = []
    if not isinstance(record, dict):
        return ['record: expected object']
    for key in ('id', 'source_id', 'source_type', 'language', 'category', 'family_id',
                'source_file', 'source_sha256', 'review_note'):
        if not isinstance(record.get(key), str) or not record[key].strip():
            errors.append(f'{key}: required nonempty string')
    if record.get('source_type') not in ('synthetic', 'real', 'real_history'):
        errors.append('source_type: expected synthetic, real or real_history')
    prefix = 'v1-syn-' if record.get('source_type') == 'synthetic' else 'v1-real-'
    if not isinstance(record.get('id'), str) or not record['id'].startswith(prefix):
        errors.append('id: must match source_type v1 prefix')
    if not isinstance(record.get('source_sha256'), str) or not re.fullmatch(r'[0-9a-f]{64}', record['source_sha256']):
        errors.append('source_sha256: expected lowercase SHA256 hex')
    if record.get('label_status') != 'weak_agent_draft':
        errors.append('label_status: expected weak_agent_draft')
    if record.get('full_tree_supervision') is not False:
        errors.append('full_tree_supervision: must be false')
    text, source = record.get('text'), record.get('source_text')
    if not isinstance(text, str) or not text or not isinstance(source, str):
        return errors + ['text/source_text: expected nonempty text and source string']
    source_bounds = _span(record.get('source_offsets'), source, 'source_offsets', errors, False)
    if source_bounds and source[slice(*source_bounds)] != text:
        errors.append('source_offsets: text is not the exact source substring')
    words, starts, ends = tokenize(text)
    for key, expected in [('words', words), ('token_starts', starts), ('token_ends', ends)]:
        actual = record.get(key)
        if actual != expected or (key != 'words' and isinstance(actual, list) and any(not _integer(v) for v in actual)):
            errors.append(f'{key}: does not match deterministic regex tokens/offsets')
    label = record.get('label')
    if label not in ('repair', 'keep', 'ambiguous'):
        errors.append('label: expected repair, keep or ambiguous')
    deletion = record.get('delete_spans')
    bounds = []
    if not isinstance(deletion, list):
        errors.append('delete_spans: expected list')
    else:
        for i, span in enumerate(deletion):
            result = _span(span, text, f'delete_spans[{i}]', errors)
            if result:
                bounds.append(result)
        ordered = sorted(bounds)
        if any(a[1] > b[0] for a, b in zip(ordered, ordered[1:])):
            errors.append('delete_spans: overlapping deletion spans')
        output = text
        for start, end in reversed(ordered):
            output = output[:start] + output[end:]
        if record.get('proposed_output') != output:
            errors.append('proposed_output: does not equal exact deletions')
    cues = record.get('cue_spans', [])
    if not isinstance(cues, list):
        errors.append('cue_spans: expected list')
        cues = []
    cue_bounds = [_span(s, text, f'cue_spans[{i}]', errors) for i, s in enumerate(cues)]
    cue_bounds = [s for s in cue_bounds if s]
    if label != 'repair':
        if deletion != [] or record.get('proposed_output') != text:
            errors.append('keep/ambiguous: edits prohibited')
        if record.get('repair_edge') is not None or record.get('internal_edges') != []:
            errors.append('keep/ambiguous: repair supervision prohibited')
        if any(record.get(k) for k in ('earlier_span', 'latest_span', 'abandoned_token_ids', 'latest_token_ids', 'cue_spans')):
            errors.append('keep/ambiguous: repair spans/token IDs/cues prohibited')
        return errors
    earlier = _span(record.get('earlier_span'), text, 'earlier_span', errors)
    latest = _span(record.get('latest_span'), text, 'latest_span', errors)
    if earlier and latest and earlier[1] > latest[0]:
        errors.append('earlier_span: must precede latest_span without overlap')
    if record.get('boundary_constraint') != 'no_outside_lexical_descendants':
        errors.append('boundary_constraint: expected no_outside_lexical_descendants')
    def token_ids(span, name):
        if span is None:
            return []
        ids = []
        for i, (word, start, end) in enumerate(zip(words, starts, ends), 1):
            if lexical(word) and _overlap(span, (start, end)):
                if not span[0] <= start < end <= span[1]:
                    errors.append(f'{name}: cuts lexical token {i}')
                ids.append(i)
        if not ids:
            errors.append(f'{name}: needs lexical tokens')
        return ids
    abandoned = token_ids(earlier, 'earlier_span')
    retained = token_ids(latest, 'latest_span')
    for key, expected in [('abandoned_token_ids', abandoned), ('latest_token_ids', retained)]:
        actual = record.get(key)
        if actual != expected or (isinstance(actual, list) and any(not _integer(v) for v in actual)):
            errors.append(f'{key}: must equal all and only lexical tokens in span')
    for i in retained:
        if any(_overlap(span, (starts[i-1], ends[i-1])) for span in bounds):
            errors.append(f'delete_spans: latest token {i} deleted')
    for i in abandoned:
        if not any(start <= starts[i-1] and ends[i-1] <= end for start, end in bounds):
            errors.append(f'delete_spans: abandoned token {i} not completely deleted')
    # Extra lexical deletion must be an explicitly annotated removable cue.
    for i, word in enumerate(words, 1):
        if lexical(word) and i not in abandoned and any(_overlap(b, (starts[i-1], ends[i-1])) for b in bounds):
            if not any(s <= starts[i-1] and ends[i-1] <= e for s, e in cue_bounds):
                errors.append(f'delete_spans: outside lexical token {i} is not a cue')
    for cue in cue_bounds:
        if earlier and _overlap(cue, earlier):
            errors.append('cue_spans: overlap with earlier_span')
        if latest and _overlap(cue, latest):
            errors.append('cue_spans: overlap with latest_span')
        if not any(s <= cue[0] and cue[1] <= e for s, e in bounds):
            errors.append('cue_spans: cue not wholly covered by deletion')
    # Accepted reparandum is contiguous in lexical order; punctuation may stay.
    if abandoned and abandoned != [i for i in range(min(abandoned), max(abandoned)+1) if lexical(words[i-1])]:
        errors.append('earlier_span: noncontiguous lexical reparandum')
    edge = record.get('repair_edge')
    internal = record.get('internal_edges')
    if not isinstance(internal, list):
        errors.append('internal_edges: expected list')
        internal = []
    parents = {}
    root = edge.get('dep') if isinstance(edge, dict) else None
    for name, item in [('repair_edge', edge)] + [(f'internal_edges[{i}]', e) for i, e in enumerate(internal)]:
        if not isinstance(item, dict):
            errors.append(f'{name}: expected edge object')
            continue
        dep, head, rel = item.get('dep'), item.get('head'), item.get('label')
        if not (_integer(dep) and _integer(head) and 1 <= dep <= len(words) and 1 <= head <= len(words)):
            errors.append(f'{name}: invalid 1-based edge indices')
            continue
        if dep in parents:
            errors.append(f'{name}: duplicate dependent head')
        parents[dep] = head
        if dep == head:
            errors.append(f'{name}: self loop')
        if rel not in RELATIONS:
            errors.append(f'{name}: invalid UD base relation')
        if name == 'repair_edge':
            if rel != 'reparandum' or dep not in abandoned or head not in retained:
                errors.append('repair_edge: requires earlier root -> latest head, reparandum')
        elif dep not in abandoned or head not in abandoned or dep == root or rel in ('root', 'reparandum', 'punct'):
            errors.append(f'{name}: invalid local lexical internal edge')
    if set(parents) != set(abandoned):
        errors.append('internal_edges: every abandoned lexical token needs exactly one head')
    for dep in abandoned:
        current, seen = dep, set()
        while current != root:
            if current in seen:
                errors.append(f'internal_edges: cycle from token {dep}')
                break
            seen.add(current)
            if current not in parents or parents[current] not in abandoned:
                errors.append(f'internal_edges: token {dep} cannot reach repair root')
                break
            current = parents[current]
    return errors


def validate_dataset(records):
    """Report counts and all validation failures without mutating records."""
    errors, ids = [], set()
    for index, record in enumerate(records):
        issues = validate_record(record)
        rid = record.get('id') if isinstance(record, dict) else None
        if isinstance(rid, str):
            if rid in ids:
                issues.append('id: duplicate dataset ID')
            ids.add(rid)
        if issues:
            errors.append({'index': index, 'id': rid, 'errors': issues})
    return {'records': len(records), 'valid_records': len(records)-len(errors),
            'invalid_records': len(errors), 'valid': not errors,
            'labels': dict(Counter(r.get('label') for r in records if isinstance(r, dict))),
            'sources': dict(Counter(r.get('source_type') for r in records if isinstance(r, dict))),
            'errors': errors,
            'interpretation': 'Structural validation only; weak agent drafts are not semantic gold.'}


def evaluate_prediction(record, heads, labels):
    """Score exact lexical recovery, never punctuation/cue-cleanup output."""
    issues = validate_record(record)
    if issues:
        raise ValueError('; '.join(issues))
    if record['label'] == 'ambiguous':
        return {'id': record['id'], 'label': 'ambiguous', 'excluded': True}
    n = len(record['words'])
    if len(heads) != n or len(labels) != n:
        raise ValueError('prediction arrays must contain one entry per regex token')
    if any(not _integer(h) or not 0 <= h <= n for h in heads):
        raise ValueError('predicted heads must be 1-based with 0 as ROOT')
    if any(r not in RELATIONS for r in labels):
        raise ValueError('predicted labels must be UD base relations')
    cycles = False
    for dep in range(1, n+1):
        seen, current = set(), dep
        while current:
            if current in seen:
                cycles = True
                break
            seen.add(current)
            current = heads[current-1]
    repairs = [i for i, rel in enumerate(labels, 1) if rel == 'reparandum']
    result = {'id': record['id'], 'label': record['label'], 'excluded': False,
              'prediction_has_cycle': cycles, 'predicted_repair_token_ids': repairs}
    if record['label'] == 'keep':
        return dict(result, false_repair_count=len(repairs), keep_no_false_repair=not repairs,
                    keep_structure_safe=not repairs and not cycles)
    root, head = record['repair_edge']['dep'], record['repair_edge']['head']
    head_correct = heads[root-1] == head and labels[root-1] == 'reparandum'
    subtree = {root}
    while True:
        children = {i for i, h in enumerate(heads, 1) if h in subtree}
        expanded = subtree | children
        if expanded == subtree:
            break
        subtree = expanded
    lexical_subtree = sorted(i for i in subtree if lexical(record['words'][i-1]))
    exact = lexical_subtree == record['abandoned_token_ids']
    latest_protected = not set(lexical_subtree).intersection(record['latest_token_ids'])
    extras = [i for i in repairs if i != root]
    complete = head_correct and exact and latest_protected and not cycles
    return dict(result, head_only_correct=head_correct,
                extra_repair_token_ids=extras, extra_repair_count=len(extras),
                repair_no_extra_repair=not extras,
                complete_structure_without_extra_repairs=complete and not extras,
                exact_lexical_subtree=exact, latest_protected=latest_protected,
                complete_lexical_span_correct=complete,
                predicted_abandoned_token_ids=lexical_subtree)


def evaluate_predictions(records, predictions):
    """Aggregate predictions supplied as {record_id: {heads: [...], labels: [...]}}."""
    details = [evaluate_prediction(r, [], [])
               if r['label'] == 'ambiguous' else evaluate_prediction(r, **predictions[r['id']])
               for r in records]
    repairs = [d for d in details if d['label'] == 'repair']
    keeps = [d for d in details if d['label'] == 'keep']
    return {'repair_records': len(repairs), 'keep_records': len(keeps),
            'ambiguous_excluded': sum(d['excluded'] for d in details),
            'head_only_correct': sum(d['head_only_correct'] for d in repairs),
            'complete_lexical_span_correct': sum(d['complete_lexical_span_correct'] for d in repairs),
            'latest_protected': sum(d['latest_protected'] for d in repairs),
            'repair_extra_repair_tokens': sum(d['extra_repair_count'] for d in repairs),
            'repair_no_extra_repair': sum(d['repair_no_extra_repair'] for d in repairs),
            'complete_structure_without_extra_repairs': sum(d['complete_structure_without_extra_repairs'] for d in repairs),
            'keep_no_false_repair': sum(d['keep_no_false_repair'] for d in keeps),
            'keep_structure_safe': sum(d['keep_structure_safe'] for d in keeps),
            'keep_cyclic_predictions': sum(d['prediction_has_cycle'] for d in keeps),
            'keep_false_repair_tokens': sum(d['false_repair_count'] for d in keeps),
            'details': details,
            'scope': 'Lexical structural recovery only; punctuation and cue cleanup not scored.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='+', type=Path)
    args = parser.parse_args()
    records = []
    for path in args.paths:
        rows = json.loads(path.read_text())
        if not isinstance(rows, list):
            parser.error(f'{path}: expected JSON list')
        records.extend(rows)
    report = validate_dataset(records)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['valid'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
