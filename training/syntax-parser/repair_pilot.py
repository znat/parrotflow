"""Matched natural/enriched multilingual block-11 pilots, using official splits.

Syntax dev selects checkpoints; a separate repair-enriched dev audit measures
repair arcs. Neither private history nor test splits are used for training.
"""
import argparse
import hashlib
import json
import random
from collections import Counter
from pathlib import Path

import torch

from data import RELATIONS, read_prepared, write_json
from diagnose import compare_layers
from english_pilot import encode_pair
from features import load_encoder
from model import ParserHead, decode
from train import evaluate


def identity(row):
    return row['treebank'], row['id']


def counts(rows):
    return {'sentences': len(rows), 'repair_sentences': sum('reparandum' in r['labels'] for r in rows),
            'repair_arcs': sum(r['labels'].count('reparandum') for r in rows),
            'treebanks': dict(Counter(r['treebank'] for r in rows))}


def select(tokenizer, config):
    rng = random.Random(42)
    manifest = read_prepared('artifacts/data')
    pools = {'train': {}, 'dev': {}}
    for item in manifest['files']:
        if item['split'] in pools and item['treebank'] not in config['evaluation_only']:
            pools[item['split']][item['treebank']] = [json.loads(line) for line in
                (Path('artifacts/data') / item['path']).read_text().splitlines()]
    # Block exact matches to ANY official dev sentence, not just sampled dev.
    dev_keys = {tuple(r['words']) for rows in pools['dev'].values() for r in rows}
    exclusions, selected = Counter(), {'natural': [], 'enriched': [], 'dev': [], 'audit': []}
    seen_train, seen_dev = set(), set()
    for bank in sorted(pools['train']):
        eligible = []
        for row in pools['train'][bank]:
            key = tuple(row['words'])
            reason = ('matches_official_dev' if key in dev_keys else
                      'duplicate_train' if key in seen_train else
                      'overlength' if len(tokenizer(row['words'], is_split_into_words=True)['input_ids']) > config['max_subwords'] else None)
            if reason:
                exclusions[reason] += 1
                exclusions[reason + '_repair_arcs'] += row['labels'].count('reparandum')
                continue
            seen_train.add(key)
            eligible.append({**row, 'relation_names': RELATIONS})
        positives = [r for r in eligible if 'reparandum' in r['labels']]
        negatives = [r for r in eligible if 'reparandum' not in r['labels']]
        rng.shuffle(negatives)
        enriched = positives + negatives[:300]
        selected['enriched'].extend(enriched)
        selected['natural'].extend(rng.sample(eligible, len(enriched)))
        dev = []
        for row in pools['dev'][bank]:
            key = tuple(row['words'])
            if key in seen_dev:
                exclusions['duplicate_dev'] += 1
                continue
            if len(tokenizer(row['words'], is_split_into_words=True)['input_ids']) > config['max_subwords']:
                exclusions['overlength_dev'] += 1
                continue
            seen_dev.add(key)
            dev.append({**row, 'relation_names': RELATIONS})
        rng.shuffle(dev)
        selected['dev'].extend(dev[:200])
        audit = {identity(r): r for r in dev[:200] + [r for r in dev if 'reparandum' in r['labels']]}
        selected['audit'].extend(audit.values())
    for name in ('natural', 'enriched'):
        assert not ({tuple(r['words']) for r in selected[name]} & dev_keys)
    return selected, dict(exclusions)


def load_head(path):
    checkpoint = torch.load(path, weights_only=True)
    head = ParserHead(**checkpoint['settings'])
    head.load_state_dict(checkpoint['head'])
    return head.eval()


def probe(head, rows):
    results = []
    with torch.inference_mode():
        for row in rows:
            arcs, labels = head(row['features'].float().unsqueeze(0), torch.ones(1, len(row['words']), dtype=torch.bool))
            parents, relations = decode(arcs[0], labels[0], len(row['words']), RELATIONS)
            result = {k: v for k, v in row.items() if k != 'features'}
            result.update(heads=parents, relations=relations,
                          repair_arcs=[{'index': i + 1, 'word': row['words'][i], 'head': parents[i],
                                        'head_word': row['words'][parents[i]-1] if parents[i] else 'ROOT'}
                                       for i, rel in enumerate(relations) if rel == 'reparandum'])
            results.append(result)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', default='artifacts/repair-pilot')
    parser.add_argument('--features-from', help='Reuse saved selection and block-11 features from a prior run')
    args = parser.parse_args()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=False)
    torch.set_num_threads(4)
    config = json.loads(Path('config.json').read_text())
    config['epochs'] = 15
    tokenizer, encoder = load_encoder(config, 'cpu')
    if args.features_from:
        prior = Path(args.features_from)
        saved = torch.load(prior / 'features.pt', weights_only=True)
        prior_experiment = json.loads((prior / 'experiment.json').read_text())
        assert prior_experiment['config'] == config
        by_id = {identity(r): {**r, 'relation_names': RELATIONS} for r in saved['rows']}
        selected = {name: [by_id[(r['treebank'], r['id'])] for r in ids]
                    for name, ids in saved['selection'].items()}
        exclusions = prior_experiment['exclusions']
    else:
        selected, exclusions = select(tokenizer, config)
    experiment = {'config': config, 'seed': 42, 'ordinary_per_treebank': 300,
                  'syntax_dev_per_treebank': 200, 'exclusions': exclusions,
                  'counts': {k: counts(v) for k, v in selected.items()},
                  'selection': {k: [{'treebank': r['treebank'], 'id': r['id']} for r in v] for k, v in selected.items()},
                  'checkpoint_selection': 'best macro-language LAS on natural dev, independently for both arms',
                  'audit': 'natural dev union all eligible repair-bearing official dev sentences; enriched precision is not deployment precision',
                  'recipe': 'frozen raw block 11, mean subword pooling, FP16 cache',
                  'features_reused_from': args.features_from,
                  'source_sha256': {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in
                                    ('repair_pilot.py', 'english_pilot.py', 'diagnose.py', 'model.py', 'train.py', 'features.py')}}
    write_json(output / 'experiment.json', experiment)
    print('Selection:', json.dumps(experiment['counts']), 'Exclusions:', json.dumps(exclusions), flush=True)
    # Encode each unique sentence once for the matched arms and shared dev sets.
    union = {identity(r): r for rows in selected.values() for r in rows}
    encoded = (list(union.values()) if args.features_from else
               encode_pair(tokenizer, encoder, list(union.values()), config['max_subwords'])['block11'])
    by_id = {identity(r): r for r in encoded}
    selected = {name: [by_id[identity(r)] for r in rows] for name, rows in selected.items()}
    caches = {name: {'train': selected[name], 'dev': selected['dev']} for name in ('natural', 'enriched')}
    torch.save({'rows': encoded, 'selection': experiment['selection']}, output / 'features.pt')
    english = torch.load('artifacts/english-pilot/block11-features.pt', weights_only=True)['dev']
    history = json.loads(Path('artifacts/english-pilot/history-probe-input.json').read_text())
    history_features = encode_pair(tokenizer, encoder, history, config['max_subwords'])['block11']
    del encoder, tokenizer
    compare_layers(config, caches, output, seed=42, epochs=15)
    results, probes = {}, {}
    for name, path in (('previous_english', Path('artifacts/english-pilot/block11-pilot.pt')),
                       ('natural', output / 'natural-pilot.pt'), ('enriched', output / 'enriched-pilot.pt')):
        head = load_head(path)
        results[name] = {'syntax_dev': evaluate(head, selected['dev'], 16, 'cpu'),
                         'repair_audit': evaluate(head, selected['audit'], 16, 'cpu'),
                         'previous_english_dev': evaluate(head, english, 16, 'cpu')}
        probes[name] = probe(head, history_features)
        print(name, json.dumps(results[name]), flush=True)
    write_json(output / 'evaluation.json', results)
    write_json(output / 'history-probes.json', probes)


if __name__ == '__main__':
    main()
