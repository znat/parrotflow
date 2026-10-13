"""Matched three-epoch head-only versus switchable LoRA continuation."""
import argparse
import hashlib
import json
import os
import time
from collections import Counter
from pathlib import Path

os.environ.setdefault('HF_HOME', str(Path('artifacts/hf-cache').resolve()))
os.environ.setdefault('HF_HUB_OFFLINE', '1')
os.environ.setdefault('TOKENIZERS_PARALLELISM', 'false')

import torch
from transformers import AutoModelForMaskedLM, AutoTokenizer
from adapters import install_adapters, set_adapters, adapter_state, load_adapter_state, prefix_states, pool_words
from data import RELATIONS, write_json
from model import batch_rows, loss_for
from repair_pilot import identity, load_head, probe
from train import evaluate


def base_hash(model):
    digest = hashlib.sha256()
    for name, value in model.named_parameters():
        if name.endswith(('lora_A', 'lora_B')):
            continue
        digest.update(name.replace('.base.', '.').encode())
        digest.update(value.detach().numpy().tobytes())
    return digest.hexdigest()


@torch.inference_mode()
def mask_probe(model, tokenizer):
    texts = ['The cat is eating a <mask>.', 'I want to edit the <mask>.',
             'Le chien mange une <mask>.', 'Je voudrais modifier le <mask>.',
             'El perro come una <mask>.', 'Quiero editar el <mask>.']
    results = []
    for text in texts:
        inputs = tokenizer(text.replace('<mask>', tokenizer.mask_token), return_tensors='pt')
        hidden = model.model(**inputs).last_hidden_state
        masked = hidden[inputs['input_ids'] == tokenizer.mask_token_id]
        assert masked.shape[0] == 1
        results.append(model.decoder(model.head(masked)).clone())
    return torch.cat(results)


class Features:
    def __init__(self, tokenizer, encoder):
        self.tokenizer, self.encoder = tokenizer, encoder

    def online(self, rows):
        inputs = self.tokenizer([r['words'] for r in rows], is_split_into_words=True,
                                padding=True, truncation=False, return_tensors='pt')
        if inputs['input_ids'].shape[1] > 256:
            raise ValueError('Never truncate a tree')
        hidden = prefix_states(self.encoder, inputs['input_ids'], inputs['attention_mask'])
        return pool_words(hidden, [inputs.word_ids(i) for i in range(len(rows))],
                          [len(r['words']) for r in rows])

    @torch.inference_mode()
    def cache(self, rows):
        result = []
        for start in range(0, len(rows), 4):
            batch = rows[start:start+4]
            features = self.online(batch)
            result.extend({**r, 'features': features[i, :len(r['words'])].half().clone()}
                          for i, r in enumerate(batch))
            if start and start % 400 == 0:
                print(f'Encoded {start}/{len(rows)}', flush=True)
        return result


def measured(head, rows):
    return {'syntax': evaluate(head, rows, 16, 'cpu'),
            'no_gold_repair_sentences': evaluate(head, [r for r in rows if 'reparandum' not in r['labels']], 16, 'cpu')}


def train_epoch(head, model, features, train, indices, optimizer, parameters, adapter_params, arm, epoch):
    started = time.perf_counter()
    head.train()
    torch.manual_seed(4200 + epoch)
    losses = []
    for step, start in enumerate(range(0, len(indices), 16), 1):
        batch = [train[i] for i in indices[start:start+16]]
        frozen, mask, parents, relations = batch_rows(batch, 'cpu')
        optimizer.zero_grad(set_to_none=True)
        words = features.online(batch) if arm == 'adapters' else frozen
        arcs, labels = head(words, mask, gold_heads=parents)
        loss = loss_for(arcs, labels, parents, relations, mask)
        if not torch.isfinite(loss):
            raise ValueError('Non-finite loss')
        loss.backward()
        if arm == 'adapters' and step == 1:
            assert any(p.grad is not None and p.grad.abs().sum() > 0 for p in adapter_params)
            assert all(p.grad is None for p in model.parameters() if not p.requires_grad)
        torch.nn.utils.clip_grad_norm_(parameters, 5.0, error_if_nonfinite=True)
        optimizer.step()
        losses.append(loss.item())
        if step % 10 == 0:
            print(f'{arm} epoch {epoch} step {step}/161 loss {sum(losses)/len(losses):.4f} elapsed {time.perf_counter()-started:.1f}s', flush=True)
    return sum(losses)/len(losses)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', default='artifacts/adapter-pilot')
    parser.add_argument('--continue-from', type=Path, help='Continue a matched completed run; recover missing optimizer state by exact replay')
    parser.add_argument('--epochs', type=int, default=3, help='Additional epochs')
    args = parser.parse_args()
    if args.epochs < 1:
        parser.error('--epochs must be positive')
    prior = None
    start_epoch = 0
    if args.continue_from:
        prior = json.loads((args.continue_from/'experiment.json').read_text())
        checkpoints = {arm: torch.load(args.continue_from/f'{arm}.pt', weights_only=True) for arm in ('head_only', 'adapters')}
        epochs = {c['epoch'] for c in checkpoints.values()}
        if len(epochs) != 1:
            raise ValueError('Matched continuation requires both checkpoints at the same epoch')
        start_epoch = epochs.pop()
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=False)
    torch.set_num_threads(4)
    torch.manual_seed(42)
    config = json.loads(Path('config.json').read_text())
    previous = Path('artifacts/repair-pilot-complete')
    saved = torch.load(previous/'features.pt', weights_only=True)
    lookup = {identity(r): {**r, 'relation_names': RELATIONS} for r in saved['rows']}
    selected = {name: [lookup[(r['treebank'], r['id'])] for r in ids]
                for name, ids in saved['selection'].items()}
    train, dev = selected['enriched'], selected['dev']
    lang_counts = Counter(r['language'] for r in train)
    weights = torch.tensor([1/lang_counts[r['language']] for r in train], dtype=torch.double)
    generator = torch.Generator().manual_seed(42)
    orders = [torch.multinomial(weights, len(train), replacement=True, generator=generator).tolist() for _ in range(start_epoch + args.epochs)]
    if prior:
        assert prior['config'] == config and prior['selection'] == saved['selection']
        assert prior['sample_orders'][:start_epoch] == orders[:start_epoch]
    tokenizer = AutoTokenizer.from_pretrained(config['model_id'], revision=config['model_revision'], local_files_only=True)
    model = AutoModelForMaskedLM.from_pretrained(config['model_id'], revision=config['model_revision'],
                                               local_files_only=True, attn_implementation='eager').eval().requires_grad_(False)
    original_hash = base_hash(model)
    original_logits = mask_probe(model, tokenizer)
    features = Features(tokenizer, model.model)
    # Check the real model's raw prefix against the original full-forward hook.
    inputs = tokenizer([r['words'] for r in dev[:4]], is_split_into_words=True, padding=True, return_tensors='pt')
    captured = []
    handle = model.model.layers[10].register_forward_hook(lambda m, a, v: captured.append(v))
    with torch.inference_mode():
        model.model(**inputs)
        expected = captured[0]
        actual = prefix_states(model.model, inputs['input_ids'], inputs['attention_mask'])
        assert torch.equal(expected, actual), 'Prefix differs from full-model hook'
    handle.remove()
    del captured, expected, actual
    torch.manual_seed(42)
    install_adapters(model.model)
    initial_adapter_state = adapter_state(model.model)
    assert torch.equal(original_logits, mask_probe(model, tokenizer)), 'Zero adapters alter MLM'
    adapter_params = [p for p in model.parameters() if p.requires_grad]
    experiment = {'config': config, 'epochs': args.epochs, 'start_epoch': start_epoch, 'end_epoch': start_epoch + args.epochs,
                  'continued_from': str(args.continue_from) if args.continue_from else None, 'batch_size': 16, 'seed': 42, 'learning_rate': 0.0001,
                  'rank': 4, 'alpha': 8, 'blocks': 11, 'adapter_parameters': sum(p.numel() for p in adapter_params),
                  'initial_checkpoint': str(previous/'enriched-pilot.pt'), 'selection': saved['selection'],
                  'sample_orders': orders, 'selection_metric': 'macro-language syntax dev LAS, including starting checkpoint',
                  'source_sha256': {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in
                                    ('adapter_pilot.py', 'adapters.py', 'model.py', 'train.py')},
                  'original_base_sha256': original_hash, 'prefix_exact': True}
    write_json(output/'experiment.json', experiment)
    baseline = load_head(previous/'enriched-pilot.pt')
    baseline_metrics = measured(baseline, dev)
    print('Baseline', json.dumps(baseline_metrics['syntax']['all']), flush=True)
    english = torch.load('artifacts/english-pilot/block11-features.pt', weights_only=True)['dev']
    history = json.loads(Path('artifacts/english-pilot/history-probe-input.json').read_text())
    set_adapters(model.model, False)
    history_frozen = features.cache(history)
    results = {'baseline': {'syntax_dev': baseline_metrics,
                           'repair_audit': measured(baseline, selected['audit']),
                           'english_dev': measured(baseline, english)}}
    probes = {'baseline': probe(baseline, history_frozen)}
    all_history = {}
    for arm in ('head_only', 'adapters'):
        head = load_head(previous/'enriched-pilot.pt')
        load_adapter_state(model.model, initial_adapter_state)
        set_adapters(model.model, arm == 'adapters')
        parameters = list(head.parameters()) + (adapter_params if arm == 'adapters' else [])
        optimizer = torch.optim.AdamW(parameters, lr=0.0001)
        starting_metrics = baseline_metrics
        if prior:
            prior_checkpoint = checkpoints[arm]
            if 'optimizer' in prior_checkpoint:
                head.load_state_dict(prior_checkpoint['head'])
                if arm == 'adapters':
                    load_adapter_state(model.model, prior_checkpoint['adapters'])
                optimizer.load_state_dict(prior_checkpoint['optimizer'])
                recovery = 'loaded optimizer state'
            else:
                # Original pilot saved only weights. Replay the identical updates,
                # requiring bitwise checkpoint agreement before any new training.
                for epoch, indices in enumerate(orders[:start_epoch], 1):
                    train_epoch(head, model, features, train, indices, optimizer, parameters, adapter_params, arm, epoch)
                assert all(torch.equal(value, prior_checkpoint['head'][key]) for key, value in head.state_dict().items()), 'Head replay mismatch'
                if arm == 'adapters':
                    assert all(torch.equal(value, prior_checkpoint['adapters'][key]) for key, value in adapter_state(model.model).items()), 'Adapter replay mismatch'
                recovery = 'exact replay; all checkpoint weights bitwise identical'
            starting_rows = features.cache(dev) if arm == 'adapters' else dev
            starting_metrics = measured(head, starting_rows)
            assert starting_metrics['syntax']['macro_language_las'] == prior_checkpoint['dev_macro_language_las']
            write_json(output/f'{arm}-recovery.json', {'method': recovery, 'starting_epoch': start_epoch,
                       'checkpoint_sha256': hashlib.sha256((args.continue_from/f'{arm}.pt').read_bytes()).hexdigest(),
                       'starting_metrics': starting_metrics})
            print(f'{arm}: optimizer recovered, epoch {start_epoch} metrics match', flush=True)
        best = starting_metrics['syntax']['macro_language_las']
        records = [{'epoch': start_epoch, 'dev': starting_metrics}]
        def save(epoch):
            torch.save({'head': head.state_dict(), 'settings': head.settings, 'epoch': epoch,
                        'adapters': adapter_state(model.model) if arm == 'adapters' else {},
                        'dev_macro_language_las': best, 'experiment': experiment, 'optimizer': optimizer.state_dict()}, output/f'{arm}.pt')
        save(start_epoch)
        for epoch, indices in enumerate(orders[start_epoch:], start_epoch + 1):
            started = time.perf_counter()
            mean_loss = train_epoch(head, model, features, train, indices, optimizer, parameters, adapter_params, arm, epoch)
            dev_features = features.cache(dev) if arm == 'adapters' else dev
            metrics = measured(head, dev_features)
            records.append({'epoch': epoch, 'loss': mean_loss, 'seconds': time.perf_counter()-started, 'dev': metrics})
            if metrics['syntax']['macro_language_las'] > best:
                best = metrics['syntax']['macro_language_las']
                save(epoch)
            write_json(output/f'{arm}-history.json', records)
            print(f'{arm} epoch {epoch} macro LAS {metrics["syntax"]["macro_language_las"]:.5f}', flush=True)
        all_history[arm] = records
        checkpoint = torch.load(output/f'{arm}.pt', weights_only=True)
        head.load_state_dict(checkpoint['head'])
        if arm == 'adapters':
            load_adapter_state(model.model, checkpoint['adapters'])
        union = {identity(r): r for rows in (dev, selected['audit'], english) for r in rows}
        encoded = features.cache(list(union.values())) if arm == 'adapters' else list(union.values())
        by_id = {identity(r): r for r in encoded}
        results[arm] = {'selected_epoch': checkpoint['epoch'], **{
            name: measured(head, [by_id[identity(r)] for r in rows]) for name, rows in
            (('syntax_dev', dev), ('repair_audit', selected['audit']), ('english_dev', english))}}
        probes[arm] = probe(head, features.cache(history) if arm == 'adapters' else history_frozen)
        write_json(output/'evaluation.json', results)
        write_json(output/'history-probes.json', probes)
    set_adapters(model.model, False)
    final_logits = mask_probe(model, tokenizer)
    final_hash = base_hash(model)
    parity = {'base_weights_unchanged': original_hash == final_hash,
              'disabled_mlm_logits_exact': torch.equal(original_logits, final_logits),
              'max_logit_difference': (original_logits-final_logits).abs().max().item(),
              'masked_positions': 6, 'vocabulary_size': original_logits.shape[-1],
              'scope': 'Pinned PyTorch model, six EN/FR/ES probes; not CoreML/app parity'}
    write_json(output/'parity.json', parity)
    assert parity['base_weights_unchanged'] and parity['disabled_mlm_logits_exact']
    print('DONE', json.dumps(parity), flush=True)


if __name__ == '__main__':
    main()
