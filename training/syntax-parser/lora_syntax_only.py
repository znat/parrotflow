"""Fixed two-epoch English UD-only LoRA pilot with matched frozen-head control."""
import argparse
import hashlib
import json
import os
import time
from pathlib import Path

os.environ.setdefault('HF_HOME', str(Path('artifacts/hf-cache').resolve()))
os.environ.setdefault('HF_HUB_OFFLINE', '1')
os.environ.setdefault('TOKENIZERS_PARALLELISM', 'false')
import torch
from transformers import AutoModelForMaskedLM, AutoTokenizer
from adapters import install_adapters, set_adapters, adapter_state, prefix_states, pool_words
from adapter_pilot import mask_probe
from data import RELATIONS, write_json
from english_diversity_pilot import read, digest, row_key, PINNED, ENGLISH, ud_targets
from english_ud_expansion import state_hash
from model import ParserHead, batch_rows, decode, loss_for
from prepare_stanza_english_data import content_keys
from train import evaluate


def base_hash(model):
    h = hashlib.sha256()
    for name, value in model.state_dict().items():
        if name.endswith(('lora_A', 'lora_B')):
            continue
        h.update(name.replace('.base.', '.').encode())
        h.update(value.detach().cpu().contiguous().numpy().tobytes())
    return h.hexdigest()


def pooling_matrix(word_ids, counts, device):
    weights = torch.zeros(len(counts), max(counts), len(word_ids[0]))
    for i, count in enumerate(counts):
        for j, word in enumerate(word_ids[i]):
            if word is not None:
                weights[i, word, j] = 1
        assert torch.all(weights[i, :count].sum(-1) > 0)
    return (weights / weights.sum(-1, keepdim=True).clamp_min(1)).to(device)


class OnlineFeatures:
    def __init__(self, tokenizer, model, device):
        self.tokenizer, self.model, self.device = tokenizer, model, device

    def inputs(self, rows):
        tokens = self.tokenizer([r['words'] for r in rows], is_split_into_words=True,
                               padding=True, truncation=False, return_tensors='pt')
        assert tokens['input_ids'].shape[1] <= 256, 'Never truncate trees'
        weights = pooling_matrix([tokens.word_ids(i) for i in range(len(rows))],
                                 [len(r['words']) for r in rows], self.device)
        return tokens.to(self.device), weights

    def __call__(self, rows):
        tokens, weights = self.inputs(rows)
        hidden = prefix_states(self.model.model, tokens['input_ids'], tokens['attention_mask'])
        return torch.bmm(weights, hidden).half().float()

    @torch.no_grad()
    def cache(self, rows, batch_size=16):
        result = []
        for start in range(0, len(rows), batch_size):
            batch = rows[start:start + batch_size]
            features = self(batch).cpu().half()
            result.extend({**r, 'features': features[i, :len(r['words'])].clone(),
                           'relation_names': RELATIONS} for i, r in enumerate(batch))
        return result


def load_groups():
    data_dir = Path('artifacts/stanza-english-data')
    manifest = read(data_dir/'manifest.json')
    sources = [data_dir/'manifest.json', PINNED, ENGLISH]
    for section in ('source_sha256', 'output_sha256', 'protection_sha256', 'preparation_sha256'):
        for name, expected in manifest[section].items():
            path = data_dir/name if section in ('source_sha256', 'output_sha256') else Path(name)
            assert digest(path) == expected, path
            sources.append(path)
    saved = torch.load(PINNED, weights_only=True, mmap=True)
    lookup = {row_key(r): r for r in saved['rows']}
    dev = [lookup[(r['treebank'], r['id'])] for r in saved['selection']['dev']
           if lookup[(r['treebank'], r['id'])]['language'] == 'en']
    groups = {'ud': read(data_dir/'train.json'), 'dev': dev,
              'english_dev': torch.load(ENGLISH, weights_only=True, mmap=True)['dev']}
    # Match the previous GUM development partition exactly; local rows are used
    # only to define the historical exclusion boundary, never for training.
    historic = set()
    for path in Path('artifacts/data').glob('en_*-train.jsonl'):
        sources.append(path)
        for line in path.read_text().splitlines():
            historic.update(content_keys(json.loads(line)))
    local_path = Path('artifacts/repair-corpus-v3/train.json')
    sources.append(local_path)
    for row in groups['ud'] + read(local_path):
        historic.update(content_keys(row))
    groups['gum_dev'] = [r for r in read(data_dir/'en_gum-dev.json') if not content_keys(r) & historic]
    assert {k: len(v) for k,v in groups.items()} == {'ud': 23957, 'dev': 400, 'english_dev': 500, 'gum_dev': 1555}
    assert all(r['official_split'] == 'train' and r['language'] == 'en' for r in groups['ud'])
    keys = set().union(*(content_keys(r) for r in groups['ud']))
    for name in ('dev', 'english_dev', 'gum_dev'):
        assert not keys & set().union(*(content_keys(r) for r in groups[name])), name
    return {k: [{f:v for f,v in r.items() if f != 'features'} for r in rows] for k,rows in groups.items()}, sources


def sync(device):
    if device == 'mps': torch.mps.synchronize()


@torch.inference_mode()
def latency(head, online, rows, device, enabled):
    set_adapters(online.model.model, enabled)
    head.eval()
    def one(row):
        words = online([row])
        mask = torch.ones(words.shape[:2], dtype=torch.bool, device=device)
        arcs, labels = head(words, mask)
        decode(arcs[0], labels[0], len(row['words']), RELATIONS)
    for row in rows[:5]: one(row)
    times = []
    for row in rows:
        sync(device); started = time.perf_counter(); one(row); sync(device)
        times.append((time.perf_counter()-started)*1000)
    t = torch.tensor(times)
    return {'device': device, 'threads': torch.get_num_threads(), 'batch_size': 1,
            'scope': 'tokenization, raw encoder prefix11, word pooling, compact head, one-root CPU decoding; warm loaded model',
            'sentences': len(rows), 'word_counts': [len(r['words']) for r in rows],
            'milliseconds': times, 'median_ms': t.median().item(), 'mean_ms': t.mean().item(),
            'p95_ms': torch.quantile(t, .95).item()}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--device', default='mps')
    args = ap.parse_args()
    assert not args.output.exists(), 'Never overwrite an experiment'
    if args.device == 'mps': assert torch.backends.mps.is_available()
    torch.set_num_threads(4); torch.manual_seed(42)
    config = read('config.json')
    assert config['model_revision'] == 'abc32620dd4f6ab06f5fbe905dc25f310618e09f'
    started = time.perf_counter()
    groups, sources = load_groups()
    raw_dir = Path('artifacts/stanza-raw11-pilot-v1')
    raw_path = raw_dir/'raw-features.pt'
    sources += [Path(__file__), Path('adapters.py'), Path('model.py'), Path('train.py'), Path('data.py'),
                Path('english_diversity_pilot.py'), Path('prepare_stanza_english_data.py'),
                Path('adapter_pilot.py'), Path('english_ud_expansion.py'), Path('config.json'),
                raw_path, raw_dir/'experiment.json', raw_dir/'verification.json']
    raw = torch.load(raw_path, weights_only=True, mmap=True)
    assert raw['raw_layer'] == 11 and raw['adapters'] is False
    assert raw['experiment_sha256'] == digest(raw_dir/'experiment.json')
    assert raw['encoder_sha256'] == read(raw_dir/'verification.json')['encoder_sha256_before']
    for name in groups:
        groups[name] = [{**r, 'features': raw['features'][tuple(r['words'])], 'relation_names': RELATIONS} for r in groups[name]]
    settings = dict(hidden_size=384, relations=RELATIONS, arc_dim=128, label_dim=64, dropout=.2)
    orders = [torch.randperm(len(groups['ud']), generator=torch.Generator().manual_seed(4200+epoch)).tolist() for epoch in (1,2)]
    protocol = {'model_id': config['model_id'], 'model_revision': config['model_revision'],
        'task': 'English gold-word dependency parsing only; arc CE plus UD relation CE; no local repair objective',
        'epochs': 2, 'endpoint': 'Fixed epoch2, evaluate each epoch; no selection or tuning on evaluation scores',
        'seed': 42, 'batch_size': 16, 'device': args.device, 'encoder_mode': 'eval (base frozen); adapter gradients enabled',
        'representation': 'raw output of block11 before final norm; vectorized mean pooling then FP16 roundtrip',
        'lora': {'blocks': 11, 'rank': 4, 'alpha': 8, 'targets': ['Wqkv', 'Wo'], 'initialization': 'A Kaiming, B zero'},
        'head': settings, 'optimizer': {'type': 'AdamW', 'head_lr': .001, 'adapter_lr': .0001, 'weight_decay': .01, 'grad_clip': 5},
        'arms': ['frozen', 'lora'], 'sampling': 'each UD row once per epoch, same shuffled orders for both arms',
        'data_counts': {k:len(v) for k,v in groups.items()}, 'local_training_rows': 0,
        'ud_reparandum_arcs': sum(r == 'reparandum' for row in groups['ud'] for r in row['labels']),
        'metric': 'UAS/LAS excluding gold PUNCT; gold words, 37 base UD relations; no test-set evaluation',
        'latency_protocol': 'epoch2, first40 English dev sentences, 5 warmups, batch1, same device; includes tokenization+prefix+pool+head+decode',
        'historical_comparison': 'Large Stanza-style head trained with an additional repair task; historical reference only, not controlled',
        'sample_orders': orders, 'source_sha256': {str(p):digest(p) for p in sources}}
    args.output.mkdir(parents=True); out = args.output
    write_json(out/'protocol.json', protocol)
    print('PROTOCOL_FROZEN', digest(out/'protocol.json'), flush=True)
    tokenizer = AutoTokenizer.from_pretrained(config['model_id'], revision=config['model_revision'], local_files_only=True)
    lm = AutoModelForMaskedLM.from_pretrained(config['model_id'], revision=config['model_revision'],
        local_files_only=True, attn_implementation='eager').eval().requires_grad_(False)
    original_hash = base_hash(lm)
    assert original_hash == raw['encoder_sha256']
    original_logits = mask_probe(lm, tokenizer)
    torch.manual_seed(42); install_adapters(lm.model)
    assert base_hash(lm) == original_hash
    assert torch.equal(original_logits, mask_probe(lm, tokenizer))
    lm.to(args.device)
    online = OnlineFeatures(tokenizer, lm, args.device)
    with torch.no_grad():
        probe_rows = groups['english_dev'][:4]
        tokens, weights = online.inputs(probe_rows)
        hidden = prefix_states(lm.model, tokens['input_ids'], tokens['attention_mask'])
        legacy = pool_words(hidden, [tokens.word_ids(i) for i in range(4)], [len(r['words']) for r in probe_rows])
        fast = torch.bmm(weights, hidden).half().float()
        pool_delta = (legacy-fast).abs().max().item()
        assert torch.allclose(legacy, fast, atol=.002, rtol=.002), pool_delta
        cache_delta = max((fast[i,:len(r['words'])].cpu()-r['features'].float()).abs().max().item() for i,r in enumerate(probe_rows))
        assert cache_delta < .02, cache_delta
    adapter_params = [p for p in lm.parameters() if p.requires_grad]
    history = {}; verification = {'pooling_max_delta': pool_delta, 'raw_cache_probe_max_delta': cache_delta,
        'encoder_before_sha256': original_hash, 'data_disjoint': True}
    for arm in ('frozen', 'lora'):
        set_adapters(lm.model, arm == 'lora')
        torch.manual_seed(42); head = ParserHead(**settings).to(args.device)
        head_params = list(head.parameters())
        params = head_params + (adapter_params if arm == 'lora' else [])
        optim_groups = [{'params': head_params, 'lr': .001}]
        if arm == 'lora': optim_groups.append({'params': adapter_params, 'lr': .0001})
        optimizer = torch.optim.AdamW(optim_groups, weight_decay=.01)
        records = []; history[arm] = records
        for epoch, order in enumerate(orders, 1):
            torch.manual_seed(4200+epoch); head.train(); sync(args.device)
            epoch_start = time.perf_counter(); losses = []; seen = []
            for step, start in enumerate(range(0, len(order), 16), 1):
                indices = order[start:start+16]; seen += indices
                rows = [groups['ud'][i] for i in indices]
                optimizer.zero_grad(set_to_none=True)
                if arm == 'lora':
                    values = online(rows)
                    mask, parents, relations = [v.to(args.device) for v in ud_targets(rows, values.shape[1], RELATIONS)]
                else:
                    values, mask, parents, relations = batch_rows(rows, args.device)
                arcs, labels = head(values, mask, gold_heads=parents)
                loss = loss_for(arcs, labels, parents, relations, mask)
                assert torch.isfinite(loss)
                loss.backward()
                if arm == 'lora' and step == 1:
                    assert any(p.grad is not None and p.grad.abs().sum() > 0 for p in adapter_params)
                    assert all(p.grad is None for p in lm.parameters() if not p.requires_grad)
                torch.nn.utils.clip_grad_norm_(params, 5, error_if_nonfinite=True)
                optimizer.step(); losses.append(loss.item())
                if step % 50 == 0:
                    print('TRAIN', arm, epoch, step, '/1498', 'loss', sum(losses)/len(losses), 'seconds', time.perf_counter()-epoch_start, flush=True)
            assert sorted(seen) == list(range(len(groups['ud'])))
            sync(args.device); training_seconds = time.perf_counter()-epoch_start
            head.eval(); evaluation_start = time.perf_counter(); metrics = {}
            for name in ('dev', 'english_dev', 'gum_dev'):
                eval_rows = online.cache(groups[name]) if arm == 'lora' else groups[name]
                metrics[name] = evaluate(head, eval_rows, 16, args.device)
            record = {'epoch': epoch, 'loss': sum(losses)/len(losses), 'training_seconds': training_seconds,
                      'evaluation_seconds': time.perf_counter()-evaluation_start, 'rows_seen_once': len(seen), 'metrics': metrics}
            records.append(record); write_json(out/'history.json', history)
            weights = {'head': {k:v.detach().cpu() for k,v in head.state_dict().items()}, 'settings': settings,
                       'adapters': adapter_state(lm.model) if arm == 'lora' else {}, 'epoch': epoch,
                       'protocol_sha256': digest(out/'protocol.json')}
            torch.save(weights, out/f'{arm}-epoch{epoch}-weights.pt')
            torch.save({'optimizer': optimizer.state_dict(), 'weights': weights}, out/f'{arm}-epoch{epoch}-resume.pt')
            print('EVAL', arm, epoch, {k:{m:v['all'][m] for m in ('uas','las')} for k,v in metrics.items()}, flush=True)
        verification[arm] = {'head_parameters': sum(p.numel() for p in head_params),
            'adapter_parameters': sum(p.numel() for p in adapter_params) if arm == 'lora' else 0,
            'inference_tensor_bytes_fp32': sum(p.numel()*p.element_size() for p in params),
            'inference_file_bytes': (out/f'{arm}-epoch2-weights.pt').stat().st_size,
            'latency': latency(head, online, groups['english_dev'][:40], args.device, arm == 'lora')}
        write_json(out/'verification-progress.json', verification)
    lm.cpu(); set_adapters(lm.model, False)
    verification['encoder_after_sha256'] = base_hash(lm)
    assert verification['encoder_after_sha256'] == original_hash
    assert torch.equal(mask_probe(lm, tokenizer), original_logits), 'Disabled adapters must preserve MLM logits exactly'
    verification['disabled_mlm_logits_exact'] = True
    for path, expected in protocol['source_sha256'].items(): assert digest(path) == expected, path
    verification['sources_unchanged'] = True
    verification['total_wall_seconds'] = time.perf_counter()-started
    verification['checkpoint_sha256'] = {p.name:digest(p) for p in out.glob('*.pt')}
    write_json(out/'verification.json', verification)
    print('COMPLETE', verification['total_wall_seconds'], flush=True)


if __name__ == '__main__': main()
