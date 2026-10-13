"""Pinned, leakage-protected English UD data; never train official dev/test.

This intentionally differs from Stanza's en_combined: PUD and Pronouns remain
held-out, redacted GUMReddit is omitted, handparsed additions are not used, and
ESLSpok train extends the spoken domain. No model weights are loaded.
"""
import argparse
import hashlib
import json
import os
import re
from collections import Counter, defaultdict
from pathlib import Path

from data import RELATIONS, normalize, read_prepared, write_json

TREEBANKS = ('en_ewt', 'en_gum', 'en_gumreddit', 'en_pronouns', 'en_pud', 'en_eslspok')
PROTECTED_LOCAL = ('repair-corpus-v2/heldout.json', 'repair-corpus-v3/heldout.json',
                   'english-pilot/history-probe-input.json', 'candidate-classifier/history.json')


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def normalized_text(text):
    return ' '.join(text.casefold().split())


def content_keys(row):
    """Protect both basic-word sequences and original sentence surface text."""
    keys = set()
    words = row.get('words', row.get('tokens', []))
    if words and all(isinstance(w, str) for w in words):
        keys.add(normalized_text(' '.join(words)))
    for field in ('text', 'sentence'):
        if isinstance(row.get(field), str):
            keys.add(normalized_text(row[field]))
    return keys - {''}


def normalize_checked(row, treebank, split):
    words = row.get('tokens')
    if not isinstance(words, list) or not words:
        raise ValueError('missing_lexical_text: no basic word forms')
    if any(not isinstance(w, str) or not w.strip() or re.fullmatch('_+', w)
           for w in words):
        raise ValueError('missing_lexical_text: empty or underscore-redacted word form')
    if not isinstance(row.get('text'), str) or not row['text'].strip():
        raise ValueError('missing_lexical_text: missing sentence text')
    if not isinstance(row.get('sent_id'), str) or not row['sent_id'].strip():
        raise ValueError('malformed: missing sentence id')
    if any(isinstance(h, bool) or not (isinstance(h, int) or
           isinstance(h, str) and re.fullmatch(r'[0-9]+', h)) for h in row.get('head', [])):
        raise ValueError('malformed: non-integer basic dependency head')
    try:
        result = normalize(row, treebank)
    except (ValueError, TypeError, KeyError, OverflowError) as exc:
        raise ValueError(f'malformed: {exc}') from exc
    result['official_split'] = split
    return result


def token_length(tokenizer, row):
    # Matches the existing mmBERT parser's feature recipe, including specials.
    encoded = tokenizer(row['words'], is_split_into_words=True, truncation=False)
    ids = encoded['input_ids']
    alignments = encoded.word_ids()
    if set(i for i in alignments if i is not None) != set(range(len(row['words']))):
        raise ValueError('tokenizer lost a basic word')
    return len(ids)


def annotation_key(row):
    return (tuple(normalized_text(w) for w in row['words']), tuple(row['heads']),
            tuple(row['labels']), tuple(row['upos']))


def select_train(rows, protected_rows, tokenizer, max_subwords=256):
    """Exclude held-out matches/long rows; dedup connected text matches safely.

    When duplicate text has conflicting tokenization or annotations, discard the
    entire conflict group rather than choose an arbitrary gold tree.
    """
    protected_keys = defaultdict(set)
    protected_ids = defaultdict(set)
    for origin, protected in protected_rows:
        identity = f"{origin}:{protected.get('treebank', '')}:{protected.get('id', protected.get('case_id', ''))}"
        for key in content_keys(protected):
            protected_keys[key].add(identity)
        if protected.get('treebank') and protected.get('id'):
            protected_ids[(protected['treebank'], protected['id'])].add(identity)
    exclusions, candidates = [], []
    for row in rows:
        identity = dict(treebank=row['treebank'], id=row['id'])
        if row.get('official_split') != 'train':
            exclusions.append({**identity, 'reason': 'not_official_train', 'split': row.get('official_split')})
            continue
        matches = set(protected_ids.get((row['treebank'], row['id']), set()))
        for key in content_keys(row):
            matches.update(protected_keys.get(key, set()))
        if matches:
            exclusions.append({**identity, 'reason': 'protected_eval_overlap', 'matches': sorted(matches)})
            continue
        try:
            length = token_length(tokenizer, row)
        except ValueError as exc:
            exclusions.append({**identity, 'reason': 'tokenizer_alignment', 'detail': str(exc)})
            continue
        if length > max_subwords:
            exclusions.append({**identity, 'reason': 'overlength', 'subwords': length})
            continue
        candidates.append({**row, 'subwords': length})
    # Union-find catches transitive duplicate links through text/word sequences.
    parents = list(range(len(candidates)))
    def root(i):
        while parents[i] != i:
            parents[i] = parents[parents[i]]
            i = parents[i]
        return i
    seen = {}
    for i, row in enumerate(candidates):
        for key in content_keys(row):
            if key in seen:
                parents[root(i)] = root(seen[key])
            else:
                seen[key] = i
    groups = defaultdict(list)
    for i in range(len(candidates)):
        groups[root(i)].append(i)
    selected, conflicts = [], []
    for indices in groups.values():
        group = [candidates[i] for i in indices]
        if len({annotation_key(row) for row in group}) > 1:
            identities = [dict(treebank=r['treebank'], id=r['id']) for r in group]
            conflicts.append(dict(rows=identities, reason='conflicting_duplicate_annotations'))
            exclusions.extend(dict(treebank=r['treebank'], id=r['id'],
                                   reason='conflicting_duplicate_annotations', group=identities) for r in group)
        else:
            selected.append(group[0])
            exclusions.extend(dict(treebank=r['treebank'], id=r['id'], reason='duplicate_train',
                                   retained=dict(treebank=group[0]['treebank'], id=group[0]['id'])) for r in group[1:])
    # Verify final output independently from the exclusion loop.
    assert all(r['official_split'] == 'train' for r in selected)
    assert not any(content_keys(r).intersection(protected_keys) for r in selected)
    assert not any((r['treebank'], r['id']) in protected_ids for r in selected)
    all_keys = [key for row in selected for key in content_keys(row)]
    assert len(all_keys) == len(set(all_keys)), 'Final train duplicate escaped grouping'
    return selected, exclusions, conflicts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('artifacts/stanza-english-data'))
    parser.add_argument('--config', type=Path, default=Path('config.json'))
    parser.add_argument('--offline', action='store_true', help='Use already downloaded pinned sources only')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    out = args.output.resolve()
    if (out / 'manifest.json').exists():
        raise ValueError('Never overwrite a prepared dataset')
    sources = out / 'sources'
    sources.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault('HF_HOME', str(Path('artifacts/hf-cache').resolve()))
    from huggingface_hub import hf_hub_download
    def fetch(filename):
        return Path(hf_hub_download(config['dataset_id'], filename, repo_type='dataset',
                    revision=config['dataset_revision'], local_dir=sources, local_files_only=args.offline))
    metadata_path = fetch('metadata.json')
    card_path = fetch('README.md')
    metadata = json.loads(metadata_path.read_text())
    if 'official UD 2.18 release snapshot' not in card_path.read_text():
        raise ValueError('Pinned dataset card no longer identifies expected UD 2.18 snapshot')
    source_files = [metadata_path, card_path]
    # Only the pre-existing pinned tokenizer is loaded. No encoder/model download.
    os.environ.setdefault('HF_HOME', str(Path('artifacts/hf-cache').resolve()))
    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(config['model_id'], revision=config['model_revision'],
                                              local_files_only=True, use_fast=True)
    if not tokenizer.is_fast:
        raise ValueError('Fast tokenizer required for complete word alignment')
    import pyarrow.parquet as pq
    protected, train_candidates, official, rejected = [], [], {}, []
    files = []
    for treebank in TREEBANKS:
        meta = metadata.get(treebank)
        if not meta or meta.get('blocked'):
            rejected.append(dict(treebank=treebank, reason='source_unavailable_or_blocked'))
            continue
        for split in meta['splits']:
            path = fetch(f'parquet/{treebank}/{split}.parquet')
            source_files.append(path)
            raw = pq.read_table(path).to_pylist()
            if len(raw) != int(meta['splits'][split]['num_sentences']):
                raise ValueError(f'Metadata/parquet sentence count mismatch: {treebank}/{split}')
            split_rows, split_rejected = [], []
            seen_ids = set()
            for row in raw:
                if split in ('dev', 'test'):
                    # Even malformed/overlength eval sentences remain protected.
                    protected.append((f'official:{treebank}/{split}', {**row, 'treebank': treebank,
                                                                   'id': row.get('sent_id')}))
                ident = dict(treebank=treebank, split=split, id=row.get('sent_id'))
                try:
                    normalized = normalize_checked(row, treebank, split)
                    if normalized['id'] in seen_ids:
                        raise ValueError('malformed: duplicate official sentence id')
                    seen_ids.add(normalized['id'])
                    if split == 'train':
                        train_candidates.append(normalized)
                    else:
                        length = token_length(tokenizer, normalized)
                        if length > config['max_subwords']:
                            raise ValueError(f'overlength: {length} subwords')
                        split_rows.append({**normalized, 'subwords': length})
                except ValueError as exc:
                    split_rejected.append({**ident, 'reason': str(exc).split(':', 1)[0], 'detail': str(exc)})
            rejected.extend(split_rejected)
            filename = f'{treebank}-{split}.json'
            if split != 'train':
                write_json(out / filename, split_rows)
                official[filename] = split_rows
            files.append(dict(treebank=treebank, split=split, source=str(path.relative_to(out)),
                              source_sha256=sha256(path), official_source=meta['splits'][split]['files'],
                              license=meta['license'], raw_sentences=len(raw),
                              normalized_sentences=len(raw)-len(split_rejected),
                              rejected=dict(Counter(r['reason'] for r in split_rejected)),
                              output=filename if split != 'train' else 'train.json'))
            print(treebank, split, 'raw', len(raw), 'rejected', len(split_rejected), flush=True)
    existing = Path('artifacts/data')
    existing_manifest = read_prepared(existing)
    if existing_manifest['revision'] != config['dataset_revision']:
        raise ValueError('Existing protected UD data revision mismatch')
    protection_files = [existing / 'manifest.json']
    for item in existing_manifest['files']:
        if item['treebank'].startswith('en_') and item['split'] in ('dev', 'test'):
            path = existing / item['path']
            protection_files.append(path)
            protected.extend((f'existing:{item["treebank"]}/{item["split"]}', json.loads(line))
                             for line in path.read_text().splitlines())
    for filename in PROTECTED_LOCAL:
        path = Path('artifacts') / filename
        protection_files.append(path)
        protected.extend((f'local:{filename}', row) for row in json.loads(path.read_text()))
    selected, exclusions, conflicts = select_train(train_candidates, protected, tokenizer, config['max_subwords'])
    write_json(out / 'train.json', selected)
    write_json(out / 'rejected.json', rejected)
    write_json(out / 'train-exclusions.json', exclusions)
    write_json(out / 'conflicts.json', conflicts)
    import stanza
    stanza_dir = Path(stanza.__file__).parent / 'utils/datasets'
    recipe_files = [stanza_dir / 'prepare_tokenizer_treebank.py', stanza_dir / 'prepare_depparse_treebank.py']
    tokenizer_files = ['tokenizer.json', 'tokenizer_config.json', 'special_tokens_map.json']
    from transformers.utils.hub import cached_file
    pinned_tokenizer = {}
    for filename in tokenizer_files:
        path = cached_file(config['model_id'], filename, revision=config['model_revision'],
                           local_files_only=True, _raise_exceptions_for_missing_entries=False)
        if path:
            pinned_tokenizer[filename] = sha256(path)
    outputs = {path.name: sha256(path) for path in out.glob('*.json') if path.name != 'manifest.json'}
    manifest = dict(dataset_id=config['dataset_id'], revision=config['dataset_revision'], ud_version='2.18',
        model_id=config['model_id'], model_revision=config['model_revision'], max_subwords=config['max_subwords'],
        tokenizer_sha256=pinned_tokenizer, relations=RELATIONS,
        label_policy='base UD relations; subtypes collapsed; basic words only; no MWT surface rows',
        stanza_version=stanza.__version__, stanza_recipe_sha256={str(p): sha256(p) for p in recipe_files},
        recipe='EWT + GUM + available GUMReddit official train, with ESLSpok official train domain extension',
        differences_from_stanza=['PUD and Pronouns official test are evaluation only, never training',
          'All corpora official dev/test remain held-out, not only Stanza EWT dev/test',
          'Underscore-redacted GUMReddit forms are rejected without reconstruction',
          'Stanza handparsed extra corpus omitted: not part of pinned HF UD release',
          'ESLSpok official train retained as spoken learner domain extension',
          'Train exact text deduplication, conflicting-tree exclusion, protected-eval exclusions and max256 filtering'],
        omissions=[dict(treebank='en_gumreddit', reason='missing_lexical_text', rejected_rows=sum(
            r.get('treebank') == 'en_gumreddit' and r['reason'] == 'missing_lexical_text' for r in rejected))],
        source_sha256={str(p.relative_to(out)): sha256(p) for p in source_files},
        protection_sha256={str(p): sha256(p) for p in protection_files},
        preparation_sha256={str(p): sha256(p) for p in [Path(__file__), args.config, Path('data.py')]},
        protection='All new/existing official English dev/test, local v2/v3 heldouts, history23 and history83; casefold + whitespace collapsed sentence text and basic word sequence; official identity protected too',
        protected_rows=len(protected), files=files, train_candidates=len(train_candidates),
        train_sentences=len(selected), train_counts=dict(Counter(r['treebank'] for r in selected)),
        exclusions=dict(Counter(r['reason'] for r in exclusions)), conflicts=len(conflicts),
        official_eval_counts={name: len(rows) for name, rows in official.items()},
        output_sha256=outputs)
    write_json(out / 'manifest.json', manifest)
    print('TRAIN', manifest['train_counts'], 'exclusions', manifest['exclusions'], flush=True)


if __name__ == '__main__':
    main()
