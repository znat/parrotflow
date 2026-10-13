"""Fixed two-epoch data expansion with a frozen epoch13 mmBERT encoder.

Both heads start from the same checkpoint and fresh AdamW state. No architecture
or production changes. Larger corpus gets more steps; not a matched-step trial.
"""
import argparse
import copy
import hashlib
import os
import time
from collections import Counter
from pathlib import Path

os.environ.setdefault('HF_HOME', str(Path('artifacts/hf-cache').resolve()))
os.environ.setdefault('HF_HUB_OFFLINE', '1')
os.environ.setdefault('TOKENIZERS_PARALLELISM', 'false')

import torch
from transformers import AutoModelForMaskedLM, AutoTokenizer

from adapters import install_adapters, load_adapter_state, prefix_states, pool_words
from data import RELATIONS, write_json
from english_diversity_pilot import (read, digest, verify_lock, verified_ud_union,
                                    row_key, PINNED, ENGLISH, V3, OLD)
from english_diversity_schedule import epoch_orders, interleaved_batches
from model import ParserHead, batch_rows, loss_for, decode
from structure_supervision import structure_loss
from repair_structures import evaluate_predictions, validate_dataset
from train import evaluate
from prepare_stanza_english_data import content_keys

START = Path('artifacts/english-diversity-pilot-v3-epochs4/expanded-epoch13.pt')


def state_hash(model):
    h = hashlib.sha256()
    for name, value in model.state_dict().items():
        h.update(name.encode()); h.update(value.detach().cpu().contiguous().numpy().tobytes())
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, default=Path('artifacts/stanza-english-data'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--device', default='mps')
    args = parser.parse_args()
    assert not args.output.exists(), 'Never overwrite an experiment'
    torch.set_num_threads(4); torch.manual_seed(42)
    device = args.device
    if device == 'mps': assert torch.backends.mps.is_available()
    verify_lock(V3); verify_lock(OLD)
    config = read('config.json')
    data_manifest = read(args.data/'manifest.json')
    assert data_manifest['revision'] == config['dataset_revision']
    data_sources = []
    for section in ('source_sha256', 'output_sha256', 'protection_sha256', 'preparation_sha256'):
        for name, expected in data_manifest[section].items():
            path = args.data/name if section in ('source_sha256', 'output_sha256') else Path(name)
            assert digest(path) == expected, ('dataset provenance changed', path)
            data_sources.append(path)
    expanded = read(args.data/'train.json')
    assert all(r['language'] == 'en' and r['official_split'] == 'train' for r in expanded)
    saved = torch.load(PINNED, weights_only=True, mmap=True)
    lookup = {row_key(r): r for r in saved['rows']}
    selected = {name: [lookup[(r['treebank'], r['id'])] for r in ids
                      if lookup[(r['treebank'], r['id'])]['language'] == 'en']
                for name, ids in saved['selection'].items()}
    english = torch.load(ENGLISH, weights_only=True, mmap=True)
    old_ud, canonical, old_exclusions = verified_ud_union(selected['enriched'], english['train'],
                                                        selected['dev'], english['dev'])
    by_key = {row_key(r): r for r in expanded}
    control = []
    control_excluded = []
    for row in old_ud:
        if row_key(row) not in by_key:
            control_excluded.append(dict(treebank=row['treebank'], id=row['id']))
            continue
        full = by_key[row_key(row)]
        assert all(full[k] == row[k] for k in ('words', 'heads', 'labels'))
        control.append(full)
    groups = dict(control=control, expanded=expanded, local=read(V3/'train.json'),
                  dev=selected['dev'], english_dev=english['dev'], audit=selected['audit'],
                  v3=read(V3/'heldout.json'), v2=read(OLD/'heldout.json'),
                  history=[{**r, 'id': f"history-{r['case_id']}"}
                           for r in read('artifacts/english-pilot/history-probe-input.json')])
    # New GUM dev diagnostic: remove exact historical train surface matches as
    # well as current train matches. Never inspect GUM test performance here.
    historic = set()
    for path in Path('artifacts/data').glob('en_*-train.jsonl'):
        for line in path.read_text().splitlines(): historic.update(content_keys(__import__('json').loads(line)))
    for row in expanded + groups['local']: historic.update(content_keys(row))
    gum_dev = read(args.data/'en_gum-dev.json')
    gum_excluded = [r['id'] for r in gum_dev if content_keys(r) & historic]
    groups['gum_dev'] = [r for r in gum_dev if not content_keys(r) & historic]
    assert groups['gum_dev']
    for name in ('local', 'v3', 'v2'): assert validate_dataset(groups[name])['valid']
    assert len(groups['local']) == 2662 and len(groups['dev']) == 400 and len(groups['english_dev']) == 500
    train_words = {tuple(r['words']) for r in expanded + groups['local']}
    for name in ('dev', 'english_dev', 'audit', 'gum_dev', 'v3', 'v2', 'history'):
        assert not train_words.intersection(tuple(r['words']) for r in groups[name]), name
    groups = {name: [{k: v for k, v in row.items() if k != 'features'} for row in rows]
              for name, rows in groups.items()}
    tokenizer = AutoTokenizer.from_pretrained(config['model_id'], revision=config['model_revision'], local_files_only=True)
    demo = ['I', 'want', 'to', 'write', 'to', 'edit', 'the', 'code']
    assert tokenizer(demo, is_split_into_words=True)['input_ids'] == tokenizer(' '.join(demo))['input_ids']
    unique = {tuple(r['words']): r['words'] for rows in groups.values() for r in rows}
    for words in unique.values():
        assert len(tokenizer(words, is_split_into_words=True)['input_ids']) <= 256
    sources = [Path(__file__), START, PINNED, ENGLISH, Path('config.json'),
               Path('adapters.py'), Path('model.py'), Path('structure_supervision.py'),
               Path('partial_supervision.py'), Path('repair_structures.py'), Path('train.py'),
               Path('data.py'), Path('english_diversity_schedule.py'),
               Path('english_diversity_pilot.py'), Path('prepare_stanza_english_data.py'),
               args.data/'manifest.json', args.data/'train.json', V3/'manifest.json',
               V3/'train.json', V3/'heldout.json', OLD/'heldout.json',
               Path('artifacts/english-pilot/history-probe-input.json')] + canonical + data_sources
    experiment = dict(language='en', initial_checkpoint=str(START), initial_sha256=digest(START),
        initial_epoch=13, additional_epochs=2, seed=42, device=device,
        head_architecture='Existing biaffine ParserHead, unchanged',
        encoder='mmBERT-small raw block11 with epoch13 LoRA adapters; all encoder/adapters frozen',
        optimizer='Independent fresh AdamW states, lr=0.0001, batch16, clip5',
        endpoint='Fixed second epoch in each arm; never select on repair diagnostics',
        control_excluded_by_new_data_hygiene=control_excluded,
        gum_dev_count=len(groups['gum_dev']), gum_dev_excluded_historical_train=gum_excluded,
        ud_counts={n: len(groups[n]) for n in ('control', 'expanded')},
        ud_treebanks={n: dict(Counter(r['treebank'] for r in groups[n])) for n in ('control', 'expanded')},
        local_counts=dict(Counter(r['label'] for r in groups['local'])),
        limitation='Matched epochs, not optimizer steps or total UD/local ratio. Expansion combines data diversity, size and extra updates. Current head-only results are not directly comparable to prior adapter-training trajectories. Repair sets are previously inspected weak labels.',
        sampling='Every eligible UD row and all2662 local rows once per epoch, proportional batch interleaving; no balancing.',
        source_sha256={str(p): digest(p) for p in sources},
        data_manifest=read(args.data/'manifest.json'))
    args.output.mkdir(parents=True)
    out = args.output
    write_json(out/'experiment.json', experiment)
    lm = AutoModelForMaskedLM.from_pretrained(config['model_id'], revision=config['model_revision'],
            local_files_only=True, attn_implementation='eager').eval().to(device)
    checkpoint = torch.load(START, weights_only=True, map_location='cpu')
    install_adapters(lm.model); load_adapter_state(lm.model, checkpoint['adapters'])
    lm.requires_grad_(False)
    before_hash = state_hash(lm)
    started = time.perf_counter()
    cache = {}
    words_list = sorted(unique.values(), key=len)
    with torch.no_grad():
        for start in range(0, len(words_list), 8):
            batch = words_list[start:start+8]
            tokens = tokenizer(batch, is_split_into_words=True, padding=True, truncation=False, return_tensors='pt')
            ids = [tokens.word_ids(i) for i in range(len(batch))]
            hidden = prefix_states(lm.model, tokens['input_ids'].to(device), tokens['attention_mask'].to(device))
            pooled = pool_words(hidden, ids, list(map(len, batch))).cpu().half()
            for words, values in zip(batch, pooled): cache[tuple(words)] = values[:len(words)].clone()
            if start % 512 == 0: print('CACHE', start, '/', len(words_list), 'seconds', time.perf_counter()-started, flush=True)
    for name, rows in groups.items():
        groups[name] = [{**r, 'features': cache[tuple(r['words'])], 'relation_names': RELATIONS} for r in rows]
    torch.save(dict(features=cache, initial_checkpoint_sha256=digest(START),
                    experiment_sha256=digest(out/'experiment.json')), out/'features.pt')
    # After this point only the small parser head is on GPU. Keep the frozen LM
    # available on CPU for the end-of-run byte comparison, not in the optimizer.
    lm.cpu()
    if device == 'mps': torch.mps.empty_cache()

    @torch.inference_mode()
    def assess(head, tag):
        head.eval()
        result = {name: evaluate(head, groups[name], 16, device) for name in ('dev', 'english_dev', 'audit', 'gum_dev')}
        for name in ('v3', 'v2', 'history'):
            predictions = {}; probes = []
            for start in range(0, len(groups[name]), 16):
                rows = groups[name][start:start+16]
                values = torch.nn.utils.rnn.pad_sequence([r['features'].float() for r in rows], batch_first=True).to(device)
                lengths = torch.tensor([len(r['words']) for r in rows], device=device)
                mask = torch.arange(values.shape[1], device=device)[None] < lengths[:, None]
                arcs, labels = head(values, mask)
                for i, r in enumerate(rows):
                    parents, relations = decode(arcs[i], labels[i], len(r['words']), RELATIONS)
                    predictions[r['id']] = dict(heads=parents, labels=relations)
                    if name == 'history': probes.append(dict(case_id=r['case_id'], words=r['words'],
                            text=r['sentence'], heads=parents, labels=relations))
            result[name] = (probes if name == 'history' else
                            dict(metrics=evaluate_predictions(groups[name], predictions), predictions=predictions))
        write_json(out/f'{tag}-evaluation.json', result)
        print('EVAL', tag, 'LAS', result['dev']['all']['las'],
              'v3_strict', result['v3']['metrics']['complete_structure_without_extra_repairs'],
              'v2_strict', result['v2']['metrics']['complete_structure_without_extra_repairs'], flush=True)
        return result

    def new_head():
        head = ParserHead(**checkpoint['settings']).to(device)
        head.load_state_dict(checkpoint['head']); return head

    baseline = assess(new_head(), 'baseline')
    previous = read(START.parent/'evaluation.json')['expanded']['syntax_dev']['syntax']['all']['las']
    assert abs(baseline['dev']['all']['las']-previous) < 0.0025, 'Investigate feature/device parity before training'
    for name in ('v2', 'v3'):
        prior = read(START.parent/f'expanded-{name}-heldout-structure-audit.json')['metrics']
        for key in ('complete_structure_without_extra_repairs', 'keep_no_false_repair'):
            assert baseline[name]['metrics'][key] == prior[key], ('baseline mismatch', name, key)
    history = []
    for arm in ('control', 'expanded'):
        torch.manual_seed(42)
        head = new_head()
        optimizer = torch.optim.AdamW(head.parameters(), lr=0.0001)
        for epoch in (1, 2):
            head.train(); torch.manual_seed(4211+epoch)
            losses = {'ud': [], 'local': []}; seen = {'ud': [], 'local': []}
            schedule = interleaved_batches(*epoch_orders(len(groups[arm]), len(groups['local']), epoch))
            for step, (kind, indices) in enumerate(schedule, 1):
                rows = [(groups[arm] if kind == 'ud' else groups['local'])[i] for i in indices]
                optimizer.zero_grad(set_to_none=True)
                if kind == 'ud':
                    values, mask, parents, rels = batch_rows(rows, device)
                    arcs, labels = head(values, mask, gold_heads=parents)
                    loss = loss_for(arcs, labels, parents, rels, mask)
                else:
                    values = torch.nn.utils.rnn.pad_sequence([r['features'].float() for r in rows], batch_first=True).to(device)
                    lengths = torch.tensor([len(r['words']) for r in rows], device=device)
                    mask = torch.arange(values.shape[1], device=device)[None] < lengths[:, None]
                    arcs, labels = head(values, mask)
                    loss = structure_loss(arcs, labels, rows, RELATIONS)
                assert torch.isfinite(loss), (arm, epoch, step)
                loss.backward(); torch.nn.utils.clip_grad_norm_(head.parameters(), 5, error_if_nonfinite=True)
                optimizer.step(); losses[kind].append(loss.item()); seen[kind].extend(indices)
                if step % 100 == 0: print('TRAIN', arm, epoch, step, '/', len(schedule), 'loss', loss.item(), flush=True)
            assert sorted(seen['ud']) == list(range(len(groups[arm])))
            assert sorted(seen['local']) == list(range(len(groups['local'])))
            tag = f'{arm}-epoch{epoch}'
            torch.save(dict(head={k: v.detach().cpu() for k, v in head.state_dict().items()},
                settings=head.settings, adapters=checkpoint['adapters'], optimizer=optimizer.state_dict(),
                epoch=epoch, arm=arm, experiment_sha256=digest(out/'experiment.json')), out/f'{tag}.pt')
            assess(head, tag)
            history.append(dict(arm=arm, epoch=epoch, loss={k: sum(v)/len(v) for k, v in losses.items()},
                                row_coverage={k: len(v) for k, v in seen.items()}))
            write_json(out/'losses.json', history)
    after_hash = state_hash(lm)
    assert before_hash == after_hash
    assert all(digest(p) == sha for p, sha in experiment['source_sha256'].items())
    write_json(out/'verification.json', dict(encoder_sha256_before=before_hash,
        encoder_sha256_after=after_hash, elapsed_seconds=time.perf_counter()-started,
        checkpoint_sha256={p.name: digest(p) for p in out.glob('*epoch*.pt')}))
    print('COMPLETE', flush=True)


if __name__ == '__main__': main()
