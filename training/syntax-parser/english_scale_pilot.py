"""English-only two-epoch comparison of small and larger local repair supervision."""
import hashlib
import copy
import argparse
import json
import re
import time
from collections import Counter
from pathlib import Path

from adapter_pilot import Features, base_hash, mask_probe, measured, train_epoch
import torch
from transformers import AutoModelForMaskedLM, AutoTokenizer
from adapters import install_adapters, adapter_state, load_adapter_state, set_adapters
from data import RELATIONS, write_json
from model import decode
from structure_supervision import structure_loss
from repair_structures import validate_dataset, evaluate_predictions
from repair_pilot import identity, load_head, probe
from compare_candidate_rules import rule, score

OUT = None
START = Path('artifacts/adapter-pilot-epochs9/adapters.pt')


def normalized(text):
    return ' '.join(re.findall(r'\w+', text.casefold()))


@torch.inference_mode()
def history_audit(head, features, templates, cases):
    head.eval()
    sentences = features.cache(templates)
    tokens = {r['id']: [dict(t) for t in r['tokens']] for r in cases}
    for sent in sentences:
        arcs, labels = head(sent['features'].float().unsqueeze(0), torch.ones(1, len(sent['ids']), dtype=torch.bool))
        parents, relations = decode(arcs[0], labels[0], len(sent['ids']), RELATIONS)
        for i, token_id in enumerate(sent['ids']):
            t = tokens[sent['row']][token_id]
            rel = relations[i]
            t.update(head=sent['ids'][parents[i]-1] if parents[i] else -1, raw_dep=rel,
                     dep='poss' if rel == 'nmod' and t['possessive'] else rule.normalize(rel))
    outputs = []
    for row in cases:
        cuts = rule.cuts(row['text'], tokens[row['id']])
        text = row['text']
        for cut in reversed(cuts):
            text = text[:cut['start']] + text[cut['end']:]
        outputs.append({**row, 'parsed_tokens': tokens[row['id']], 'predicted_cuts': cuts, 'output': text})
    return {'metrics': score(outputs), 'results': outputs}


@torch.inference_mode()
def structure_audit(head, features, rows):
    """Training-exposed diagnostic, with full token predictions for inspection."""
    head.eval()
    predictions = {}
    for row in features.cache(rows):
        n = len(row['words'])
        arcs, labels = head(row['features'].float().unsqueeze(0), torch.ones(1, n, dtype=torch.bool))
        parents, relations = decode(arcs[0], labels[0], n, RELATIONS)
        predictions[row['id']] = {'heads': list(parents), 'labels': list(relations)}
    return {'scope': 'Local lexical structure diagnostic; caller supplies train or held-out provenance',
            'metrics': evaluate_predictions(rows, predictions), 'predictions': predictions}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    out = args.output
    out.mkdir(parents=True, exist_ok=False)
    torch.set_num_threads(4)
    torch.manual_seed(42)
    config = json.loads(Path('config.json').read_text())
    corpus = Path('artifacts/repair-corpus-v2')
    manifest = json.loads((corpus/'manifest.json').read_text())
    new_train = json.loads((corpus/'train.json').read_text())
    holdout = json.loads((corpus/'heldout.json').read_text())
    small = [r for r in json.loads(Path('artifacts/repair-structure-v1/provisional-candidates.json').read_text()) if r['language']=='en']
    large = small + new_train
    for name, rows in [('small', small), ('large', large), ('heldout', holdout)]:
        assert validate_dataset(rows)['valid'], name
        assert all(r['language']=='en' and r['label'] in ('repair','keep') and not r.get('quarantine_reason') for r in rows)
    assert {r['split_group_id'] for r in new_train}.isdisjoint({r['split_group_id'] for r in holdout})
    assert all(r['assigned_split']=='train' for r in new_train)
    assert all(r['assigned_split']=='heldout' for r in holdout)
    for name in ['train.json','heldout.json']:
        assert hashlib.sha256((corpus/name).read_bytes()).hexdigest()==manifest['output_sha256'][name]
    saved = torch.load('artifacts/repair-pilot-complete/features.pt', weights_only=True)
    lookup = {identity(r): {**r, 'relation_names': RELATIONS} for r in saved['rows']}
    selected = {k:[lookup[(r['treebank'],r['id'])] for r in ids if lookup[(r['treebank'],r['id'])]['language']=='en'] for k,ids in saved['selection'].items()}
    train, dev = selected['enriched'], selected['dev']
    english = torch.load('artifacts/english-pilot/block11-features.pt', weights_only=True)['dev']
    cases = json.loads(Path('artifacts/candidate-classifier/history.json').read_text())
    templates = torch.load('artifacts/candidate-classifier/history-features.pt', weights_only=True)
    history = json.loads(Path('artifacts/english-pilot/history-probe-input.json').read_text())
    tokenizer = AutoTokenizer.from_pretrained(config['model_id'], revision=config['model_revision'], local_files_only=True)
    lengths = {r['id']:len(tokenizer(r['words'],is_split_into_words=True)['input_ids']) for r in large+holdout}
    assert max(lengths.values())<=256, 'Never truncate examples or change proportions silently'
    checkpoint = torch.load(START, weights_only=True)
    assert checkpoint['epoch']==9
    prior = json.loads(Path('artifacts/adapter-pilot-epochs9/experiment.json').read_text())
    assert prior['config']==config and prior['selection']==saved['selection']
    model = AutoModelForMaskedLM.from_pretrained(config['model_id'], revision=config['model_revision'],local_files_only=True,attn_implementation='eager').eval().requires_grad_(False)
    original_hash, original_logits = base_hash(model), mask_probe(model,tokenizer)
    install_adapters(model.model)
    adapter_params = [p for p in model.parameters() if p.requires_grad]
    features = Features(tokenizer,model.model)
    generator = torch.Generator().manual_seed(4211)
    orders = [torch.randperm(len(train),generator=generator).tolist() for _ in range(2)]
    source_paths = [Path(__file__),Path('structure_supervision.py'),Path('partial_supervision.py'),Path('repair_structures.py'),Path('adapter_pilot.py'),Path('adapters.py'),Path('model.py'),corpus/'manifest.json',corpus/'train.json',corpus/'heldout.json',Path('artifacts/repair-structure-v1/provisional-candidates.json')]
    experiment = {'language':'en','epochs':2,'start_epoch':9,'end_epoch':11,'initial_checkpoint':str(START),'initial_checkpoint_sha256':hashlib.sha256(START.read_bytes()).hexdigest(),'config':config,'ud_examples_per_epoch':len(train),'ud_orders':orders,'small_counts':dict(Counter(r['label'] for r in small)),'large_counts':dict(Counter(r['label'] for r in large)),'heldout_counts':dict(Counter(r['label'] for r in holdout)),'new_train_groups':len({r['split_group_id'] for r in new_train}),'heldout_groups':len({r['split_group_id'] for r in holdout}),'sampling':'English UD once per epoch in identical seeded permutations; each assigned repair/keep row once per epoch, no rebalancing. Larger arm has more updates.','selection':'English UD dev LAS only, including starting checkpoint; synthetic holdout evaluated once after selection','label_status':'New synthetic agent drafts independently reviewed; not human gold. Existing45 English examples have user batch acceptance.','optimizer':'Independent deep-copied AdamW epoch9 state; lr0.0001','training_scope':'Parser head and existing attention adapters; base and MLM frozen','max_subword_length':max(lengths.values()),'source_sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in source_paths}}
    write_json(out/'experiment.json',experiment)
    write_json(out/'small-training-records.json',small)
    write_json(out/'large-training-records.json',large)
    write_json(out/'heldout-records.json',holdout)
    print('DATA',json.dumps({k:experiment[k] for k in ['ud_examples_per_epoch','small_counts','large_counts','heldout_counts','new_train_groups','heldout_groups']}),flush=True)
    load_adapter_state(model.model,checkpoint['adapters'])
    baseline=measured(load_head(START),features.cache(dev))
    results={}; audits={}; probes={}; local={}
    for arm, annotations in [('small',small),('large',large)]:
        head=load_head(START)
        load_adapter_state(model.model,checkpoint['adapters'])
        parameters=list(head.parameters())+adapter_params
        optimizer=torch.optim.AdamW(parameters,lr=0.0001)
        optimizer.load_state_dict(copy.deepcopy(checkpoint['optimizer']))
        for sid,state in checkpoint['optimizer']['state'].items():
            loaded=optimizer.state_dict()['state'][sid]
            for key,value in state.items():
                if isinstance(value,torch.Tensor):
                    assert torch.equal(value,loaded[key]) and value.data_ptr()!=loaded[key].data_ptr()
        best=baseline['syntax']['all']['las']; records=[{'epoch':9,'dev':baseline}]
        def save(epoch):
            torch.save({'head':head.state_dict(),'settings':head.settings,'adapters':adapter_state(model.model),'optimizer':optimizer.state_dict(),'epoch':epoch,'dev_english_las':best,'experiment':experiment,'arm':arm},out/f'{arm}.pt')
        save(9)
        for epoch,indices in enumerate(orders,10):
            started=time.perf_counter()
            ud_loss=train_epoch(head,model,features,train,indices,optimizer,parameters,adapter_params,'adapters',epoch)
            torch.manual_seed(9000+epoch)
            order=torch.randperm(len(annotations),generator=torch.Generator().manual_seed(9000+epoch)).tolist()
            head.train(); losses=[]
            for start in range(0,len(order),16):
                batch=[annotations[i] for i in order[start:start+16]]
                optimizer.zero_grad(set_to_none=True)
                words=features.online(batch)
                mask=torch.arange(words.shape[1])[None]<torch.tensor([len(r['words']) for r in batch])[:,None]
                arcs,labels=head(words,mask)
                loss=structure_loss(arcs,labels,batch,RELATIONS)
                assert torch.isfinite(loss)
                loss.backward()
                torch.nn.utils.clip_grad_norm_(parameters,5.0,error_if_nonfinite=True)
                optimizer.step();losses.append(loss.item())
            metrics=measured(head,features.cache(dev))
            records.append({'epoch':epoch,'ud_loss':ud_loss,'structure_loss':sum(losses)/len(losses),'examples_seen':len(annotations),'seconds':time.perf_counter()-started,'dev':metrics})
            if metrics['syntax']['all']['las']>best:
                best=metrics['syntax']['all']['las'];save(epoch)
            write_json(out/f'{arm}-history.json',records)
            print(arm,epoch,'LAS',metrics['syntax']['all']['las'],'structure',records[-1]['structure_loss'],flush=True)
        chosen=torch.load(out/f'{arm}.pt',weights_only=True)
        head.load_state_dict(chosen['head']);load_adapter_state(model.model,chosen['adapters']);head.eval()
        union={identity(r):r for rows in [dev,selected['audit'],english] for r in rows}
        encoded={identity(r):r for r in features.cache(list(union.values()))}
        results[arm]={'selected_epoch':chosen['epoch'],**{name:measured(head,[encoded[identity(r)] for r in rows]) for name,rows in [('syntax_dev',dev),('repair_audit',selected['audit']),('english_dev',english)]}}
        probes[arm]=probe(head,features.cache(history));audits[arm]=history_audit(head,features,templates,cases)
        local[arm]={'heldout':structure_audit(head,features,holdout),'old_training':structure_audit(head,features,small),'new_train':structure_audit(head,features,new_train)}
        local[arm]['heldout']['scope']='Previously untrained English synthetic template-group holdout; weak labels; never selects checkpoints.'
        local[arm]['old_training']['scope']='User-reviewed old English training examples; training exposed in both arms.'
        local[arm]['new_train']['scope']='Larger corpus training partition, unseen by small arm but training exposed in large arm.'
        write_json(out/'evaluation.json',results);write_json(out/'history-probes.json',probes);write_json(out/'history-audit.json',audits);write_json(out/'local-structure-audit.json',local)
        print('RESULT',arm,json.dumps({k:v for k,v in local[arm]['heldout']['metrics'].items() if k!='details'}),flush=True)
    set_adapters(model.model,False)
    logits=mask_probe(model,tokenizer)
    parity={'base_weights_unchanged':original_hash==base_hash(model),'disabled_mlm_logits_exact':torch.equal(original_logits,logits),'max_logit_difference':(original_logits-logits).abs().max().item()}
    write_json(out/'parity.json',parity)
    assert parity['base_weights_unchanged'] and parity['disabled_mlm_logits_exact']
    print('DONE',json.dumps(parity),flush=True)


if __name__=='__main__':
    main()
