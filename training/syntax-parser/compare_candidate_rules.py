"""Apply one frozen noun-phrase candidate rule to spaCy and mmBERT trees.

spaCy tokenization, sentence boundaries, POS and lemmas are shared so only the
dependency trees change. History is evaluation-only. No classifier is trained.
"""
import importlib.util
import json
from pathlib import Path

import torch

from english_pilot import encode_pair
from features import load_encoder
from repair_pilot import load_head
from model import decode
from data import RELATIONS, write_json

def __getattr__(name):
    # This historical comparison is not used by campaign.cli. Load its optional
    # reference rule only when explicitly requested, never during package import.
    if name != 'rule':
        raise AttributeError(name)
    import os
    reference = os.environ.get('PARROTFLOW_REFERENCE_RULE')
    if not reference or not Path(reference).is_file():
        raise RuntimeError('Set PARROTFLOW_REFERENCE_RULE to the historical compare-parsers.py file')
    spec = importlib.util.spec_from_file_location('frozen_rule', reference)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    globals()['rule'] = module
    return module



def score(rows):
    metrics = {}
    for name, selected in [('repairs', [r for r in rows if r['group'] == 'likely-repair']),
                           ('keep_ambiguous', [r for r in rows if r['group'] != 'likely-repair'])]:
        metrics[name] = {'cases': len(selected), 'exact_outputs': sum(r['output'] == r['expected'] for r in selected),
                         'cases_with_candidates': sum(bool(r['predicted_cuts']) for r in selected)}
    return metrics


def main():
    rule = __getattr__('rule')
    torch.set_num_threads(4)
    out = Path('artifacts/candidate-classifier')
    rows = json.loads((out / 'history.json').read_text())
    config = json.loads(Path('config.json').read_text())
    tokenizer, encoder = load_encoder(config, 'cpu')
    sentences = []
    for row in rows:
        for si, ids in enumerate(row['sentences']):
            words = [row['tokens'][i]['text'] for i in ids]
            assert len(tokenizer(words, is_split_into_words=True)['input_ids']) <= config['max_subwords']
            sentences.append({'row': row['id'], 'sentence': si, 'ids': ids, 'words': words})
    encoded = encode_pair(tokenizer, encoder, sentences, config['max_subwords'])['block11']
    torch.save(encoded, out / 'history-features.pt')
    models = {'spacy': None, 'english_block11': Path('artifacts/english-pilot/block11-pilot.pt'),
              'enriched_block11': Path('artifacts/repair-pilot-complete/enriched-pilot.pt')}
    result = {}
    for name, checkpoint in models.items():
        tokens = {r['id']: [dict(t) for t in r['tokens']] for r in rows}
        if checkpoint:
            head = load_head(checkpoint)
            with torch.inference_mode():
                for sent in encoded:
                    arcs, labels = head(sent['features'].float().unsqueeze(0), torch.ones(1, len(sent['ids']), dtype=torch.bool))
                    parents, relations = decode(arcs[0], labels[0], len(sent['ids']), RELATIONS)
                    for i, token_id in enumerate(sent['ids']):
                        token = tokens[sent['row']][token_id]
                        rel = relations[i]
                        # Training collapsed nmod:poss; recover this adapter only
                        # when the shared spaCy tag identifies a possessive pronoun.
                        normalized = 'poss' if rel == 'nmod' and token['possessive'] else rule.normalize(rel)
                        token.update(head=sent['ids'][parents[i]-1] if parents[i] else -1,
                                     raw_dep=rel, dep=normalized)
        outputs = []
        for row in rows:
            cuts = rule.cuts(row['text'], tokens[row['id']])
            if name == 'spacy':
                assert cuts == row['cuts']
            text = row['text']
            for cut in reversed(cuts):
                assert cut['start'] < cut['end']
                text = text[:cut['start']] + text[cut['end']:]
            outputs.append({**row, 'parsed_tokens': tokens[row['id']], 'predicted_cuts': cuts, 'output': text})
        result[name] = {'metrics': score(outputs), 'results': outputs}
        print(name, json.dumps(result[name]['metrics']), flush=True)
        for r in outputs:
            if r['predicted_cuts']:
                print(r['id'], r.get('span', r['text']), '=>', r['output'], r['output'] == r['expected'], flush=True)
    write_json(out / 'same-rule-comparison.json', result)


if __name__ == '__main__':
    main()
