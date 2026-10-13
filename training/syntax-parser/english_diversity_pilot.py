"""Matched fixed-epoch English v3 experiment. Never selects on repair holdouts.

Requires the exact frozen v3 manifest digest supplied explicitly at invocation.
Both arms continue epoch9 for exactly two epochs; all data are local/offline.
"""
import argparse
import copy
import hashlib
import json
import time
from collections import Counter
from pathlib import Path

from english_diversity_schedule import epoch_orders,interleaved_batches

START=Path('artifacts/adapter-pilot-epochs9/adapters.pt')
OLD=Path('artifacts/repair-corpus-v2')
V3=Path('artifacts/repair-corpus-v3')
PINNED=Path('artifacts/repair-pilot-complete/features.pt')
ENGLISH=Path('artifacts/english-pilot/block11-features.pt')


def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda:stream.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()


def read(path):return json.loads(Path(path).read_text())


def verify_lock(corpus):
    manifest=read(corpus/'manifest.json');lock=read(corpus/'split-lock.json')
    assert lock['manifest_sha256']==digest(corpus/'manifest.json'), 'split lock changed'
    for name,expected in manifest['output_sha256'].items():
        assert digest(corpus/name)==expected,(corpus,name,'output changed')
    return manifest


def row_key(row):return row['treebank'],row['id']


def verified_ud_union(old_enriched,english_train,syntax_dev,english_dev):
    """Deduplicate cached train identities and verify canonical train annotations.

    Cached feature tensors are only provenance; online adapter features are used
    for training. Scan official train JSONL incrementally, retaining wanted rows.
    """
    assert len(old_enriched)==649 and len(english_train)==2000
    union={}
    for row in old_enriched+english_train:
        key=row_key(row)
        assert row['language']=='en'
        if key in union:
            assert all(row[field]==union[key][field] for field in ('words','heads','labels'))
        else:union[key]=row
    held={row_key(r) for r in syntax_dev+english_dev}
    assert set(union).isdisjoint(held),'UD evaluation row in training'
    remaining=set(union);canonical_paths=[]
    for path in sorted(Path('artifacts/data').glob('en_*-train.jsonl')):
        canonical_paths.append(path)
        with path.open() as stream:
            for line in stream:
                canonical=json.loads(line);key=row_key(canonical)
                if key in remaining:
                    cached=union[key]
                    assert all(cached[field]==canonical[field] for field in ('language','words','heads','labels')),(key,'canonical train mismatch')
                    remaining.remove(key)
    assert not remaining,('cached UD rows absent from canonical train',sorted(remaining))
    # Official dev/test identities may never enter the union, even if not sampled.
    official_eval_words={}
    for path in sorted(Path('artifacts/data').glob('en_*.jsonl')):
        if not path.name.endswith(('-dev.jsonl','-test.jsonl')):continue
        canonical_paths.append(path)
        with path.open() as stream:
            for line in stream:
                row=json.loads(line)
                assert row_key(row) not in union,(path,'dev/test identity in train')
                split='dev' if path.name.endswith('-dev.jsonl') else 'test'
                official_eval_words.setdefault(tuple(row['words']),set()).add(split)
    exclusions=[dict(treebank=row['treebank'],id=row['id'],reason='exact_word_sequence_matches_official_eval',matching_splits=sorted(official_eval_words[tuple(row['words'])])) for row in union.values() if tuple(row['words']) in official_eval_words]
    eligible=[row for row in union.values() if tuple(row['words']) not in official_eval_words]
    assert not ({tuple(row['words']) for row in eligible} & set(official_eval_words))
    return eligible,canonical_paths,exclusions


def local_fingerprint(row):
    keys=('id','text','words','label','earlier_span','latest_span','delete_spans',
          'abandoned_token_ids','latest_token_ids','repair_edge','internal_edges','proposed_output')
    return {key:row.get(key) for key in keys}


def ud_targets(rows, width, relation_names):
    """Exactly batch_rows target tensors without allocating unused frozen features."""
    import torch
    mask=torch.zeros(len(rows),width,dtype=torch.bool)
    parents=torch.full(mask.shape,-100,dtype=torch.long)
    relations=torch.full(mask.shape,-100,dtype=torch.long)
    for i,row in enumerate(rows):
        n=len(row['words'])
        assert n<=width
        mask[i,:n]=True
        parents[i,:n]=torch.tensor(row['heads'])
        relations[i,:n]=torch.tensor([relation_names.index(label) for label in row['labels']])
    return mask,parents,relations


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--frozen-manifest-sha256',required=True,
                        help='Exact v3 manifest SHA approved after independent corpus review')
    args=parser.parse_args()
    assert digest(V3/'manifest.json')==args.frozen_manifest_sha256,'v3 not the explicitly frozen corpus'
    v3_manifest=verify_lock(V3);old_manifest=verify_lock(OLD)
    assert not args.output.exists(),'Never overwrite a prior experiment'
    # Heavy dependencies are loaded only by the authorized experiment entry point.
    import torch
    from transformers import AutoModelForMaskedLM,AutoTokenizer
    from adapter_pilot import Features,base_hash,mask_probe,measured
    from adapters import install_adapters,adapter_state,load_adapter_state,set_adapters
    from data import RELATIONS,write_json
    from model import loss_for,decode
    from structure_supervision import structure_loss
    from repair_structures import validate_dataset,evaluate_predictions
    from repair_pilot import load_head,probe
    from english_scale_pilot import history_audit
    from compare_candidate_rules import rule
    torch.set_num_threads(4);torch.manual_seed(42)
    config=read('config.json')
    old45=[r for r in read('artifacts/repair-structure-v1/provisional-candidates.json') if r['language']=='en']
    old870=read(OLD/'train.json');old_holdout=read(OLD/'heldout.json')
    control=old45+old870;expanded=read(V3/'train.json');holdout=read(V3/'heldout.json')
    assert len(old45)==45 and len(old870)==870 and len(control)==915 and len(old_holdout)==210
    for name,rows in [('control',control),('expanded',expanded),('heldout',holdout),('v2-heldout',old_holdout)]:
        assert validate_dataset(rows)['valid'],name
        assert all(r['language']=='en' and r['label'] in ('keep','repair') and not r.get('quarantine_reason') for r in rows),name
        assert len({r['id'] for r in rows})==len(rows),name
    expanded_by_id={r['id']:r for r in expanded}
    assert all(r['id'] in expanded_by_id and local_fingerprint(r)==local_fingerprint(expanded_by_id[r['id']]) for r in control),'expanded must include unchanged control915'
    assert {r['id'] for r in expanded}.isdisjoint({r['id'] for r in holdout+old_holdout})
    assert {r['text'] for r in expanded}.isdisjoint({r['text'] for r in holdout+old_holdout})
    assert {r['split_group_id'] for r in expanded if r.get('split_group_id')}.isdisjoint({r['split_group_id'] for r in holdout})
    assert all(r['assigned_split']=='train' for r in expanded)
    assert all(r['assigned_split']=='heldout' for r in holdout)
    saved=torch.load(PINNED,weights_only=True,mmap=True)
    lookup={row_key(r):{**r,'relation_names':RELATIONS} for r in saved['rows']}
    selected={name:[lookup[(r['treebank'],r['id'])] for r in ids if lookup[(r['treebank'],r['id'])]['language']=='en'] for name,ids in saved['selection'].items()}
    english_saved=torch.load(ENGLISH,weights_only=True,mmap=True)
    dev=selected['dev'];english_dev=english_saved['dev']
    assert len(dev)==400 and len(english_dev)==500
    ud,canonical_paths,ud_exclusions=verified_ud_union(selected['enriched'],english_saved['train'],dev,english_dev)
    cases=read('artifacts/candidate-classifier/history.json');assert len(cases)==83
    templates=torch.load('artifacts/candidate-classifier/history-features.pt',weights_only=True,mmap=True)
    history=read('artifacts/english-pilot/history-probe-input.json')
    checkpoint=torch.load(START,weights_only=True,mmap=True);assert checkpoint['epoch']==9
    prior=read('artifacts/adapter-pilot-epochs9/experiment.json')
    assert prior['config']==config and prior['selection']==saved['selection']
    tokenizer=AutoTokenizer.from_pretrained(config['model_id'],revision=config['model_revision'],local_files_only=True)
    for rows in (ud,control,expanded,holdout,old_holdout,dev,english_dev,selected['audit'],history,templates):
        assert all(len(tokenizer(r['words'],is_split_into_words=True)['input_ids'])<=256 for r in rows),'Never truncate or silently alter proportions'
    paths=[Path(__file__),Path('english_diversity_schedule.py'),Path('tests/test_english_diversity_schedule.py'),Path('tests/test_english_diversity_targets.py'),Path('tests/test_english_diversity_preflight.py'),
           START,PINNED,ENGLISH,Path('config.json'),Path('artifacts/data/manifest.json'),
           Path('artifacts/repair-structure-v1/provisional-candidates.json'),Path('artifacts/adapter-pilot-epochs9/experiment.json'),
           Path('artifacts/candidate-classifier/history.json'),Path('artifacts/candidate-classifier/history-features.pt'),
           Path('artifacts/english-pilot/history-probe-input.json'),Path(rule.__file__)]
    paths += [Path(name) for name in ('adapter_pilot.py','adapters.py','model.py','structure_supervision.py','partial_supervision.py','repair_structures.py','repair_pilot.py','english_scale_pilot.py','compare_candidate_rules.py','train.py','features.py','data.py')]
    paths += canonical_paths
    for corpus,manifest in [(OLD,old_manifest),(V3,v3_manifest)]:
        paths += [corpus/'manifest.json',corpus/'split-lock.json']+[corpus/name for name in manifest['output_sha256']]
        for source,expected in manifest.get('source_sha256',{}).items():
            source_path=Path(source)
            if source_path.exists():
                assert digest(source_path)==expected,(source,'frozen source changed')
                paths.append(source_path)
            elif corpus==V3:raise AssertionError((source,'frozen v3 source missing'))
    hashes={str(p):digest(p) for p in paths}
    experiment=dict(language='en',start_epoch=9,end_epoch=11,epochs=2,batch_size=16,initial_checkpoint=str(START),
                    initial_checkpoint_sha256=digest(START),config=config,source_sha256=hashes,
                    primary_endpoint='Fixed epoch11 for both arms; holdouts never select checkpoint',
                    optimizer='Separate AdamW states deep-copied from epoch9; learning rate 0.0001',
                    training_scope='Existing LoRA attention adapters and parser head only; frozen base and MLM',
                    sampling='Each UD and local row once/epoch. Identical UD permutations across arms; proportional midpoint batch interleaving throughout each epoch. No balancing or resampling; expanded has more updates.',
                    counterfactual_limitation='Matched epochs and natural UD exposure, not matched total optimizer updates. Expanded uses more local updates and a different interleaving timeline; contrast combines supervision diversity/size with update count.',
                    ud_union_before_eval_exclusion=len(ud)+len(ud_exclusions),ud_exclusions=ud_exclusions,
                    evaluation_interpretation='v3 heldout73 cue-free repairs are singleton structures. V2 heldout84 repairs include multiword subtree recovery and are a previously scored diagnostic (historical strict endpoint40/84), not a fresh generalization set.',
                    ud_examples_per_epoch=len(ud),ud_selection=[dict(treebank=r['treebank'],id=r['id']) for r in ud],
                    arm_counts={name:dict(Counter(r['label'] for r in rows)) for name,rows in [('control',control),('expanded',expanded)]},
                    heldout_counts=dict(Counter(r['label'] for r in holdout)),
                    label_status='Agent text-reviewed weak local structures; old45 previously exposed training; no labels claimed semantic gold',
                    schedules={name:{str(epoch):interleaved_batches(*epoch_orders(len(ud),len(rows),epoch)) for epoch in (10,11)} for name,rows in [('control',control),('expanded',expanded)]})
    args.output.mkdir(parents=True,exist_ok=False);out=args.output
    write_json(out/'experiment.json',experiment)
    for name,rows in [('control-training-records',control),('expanded-training-records',expanded),('heldout-records',holdout)]:write_json(out/(name+'.json'),rows)
    model=AutoModelForMaskedLM.from_pretrained(config['model_id'],revision=config['model_revision'],local_files_only=True,attn_implementation='eager').eval().requires_grad_(False)
    original_hash=base_hash(model);original_logits=mask_probe(model,tokenizer)
    install_adapters(model.model);adapter_params=[p for p in model.parameters() if p.requires_grad]
    assert adapter_params and all(name.endswith(('lora_A','lora_B')) for name,p in model.named_parameters() if p.requires_grad)
    features=Features(tokenizer,model.model)

    def syntax_audit(head,rows):
        # Largest syntax set is500 sentences. Only this bounded current feature
        # cache is retained; training source tensors remain memory-mapped.
        return measured(head,features.cache(rows))

    @torch.inference_mode()
    def local_audit(head,rows,scope):
        head.eval();predictions={}
        for start in range(0,len(rows),16):
            for row in features.cache(rows[start:start+16]):
                n=len(row['words'])
                arcs,labels=head(row['features'].float().unsqueeze(0),torch.ones(1,n,dtype=torch.bool))
                parents,relations=decode(arcs[0],labels[0],n,RELATIONS)
                predictions[row['id']]={'heads':list(parents),'labels':list(relations)}
        breakdown={}
        for field in ('source_type','cue_type','label','repair_size'):
            def value(r):
                if field=='repair_size':return 'not_applicable' if r['label']!='repair' else ('singleton' if len(r['abandoned_token_ids'])==1 else 'multiword')
                if field=='source_type':return 'synthetic' if r['source_type']=='synthetic' else 'real'
                if field=='cue_type':return r.get('cue_type','explicit' if r.get('cue_spans') else ('none' if r['label']=='repair' else 'not_applicable'))
                return r[field]
            for group in sorted({value(r) for r in rows}):
                selected_rows=[r for r in rows if value(r)==group]
                breakdown[f'{field}:{group}']=evaluate_predictions(selected_rows,predictions)
        return dict(scope=scope,metrics=evaluate_predictions(rows,predictions),breakdown=breakdown,predictions=predictions)

    evaluation={};parity={};epochs={}
    for arm,annotations in [('control',control),('expanded',expanded)]:
        head=load_head(START);load_adapter_state(model.model,checkpoint['adapters'])
        parameters=list(head.parameters())+adapter_params
        optimizer=torch.optim.AdamW(parameters,lr=0.0001)
        optimizer.load_state_dict(copy.deepcopy(checkpoint['optimizer']))
        for group in optimizer.param_groups:group['lr']=0.0001
        for sid,state in checkpoint['optimizer']['state'].items():
            for key,value in state.items():
                if isinstance(value,torch.Tensor):
                    loaded=optimizer.state_dict()['state'][sid][key]
                    assert torch.equal(value,loaded) and value.data_ptr()!=loaded.data_ptr()
        history_rows=[]
        def save(epoch):
            path=out/f'{arm}-epoch{epoch}.pt'
            assert not path.exists()
            torch.save(dict(head=head.state_dict(),settings=head.settings,adapters=adapter_state(model.model),optimizer=optimizer.state_dict(),epoch=epoch,arm=arm,experiment_manifest_sha256=digest(out/'experiment.json')),path)
            return path
        save(9)
        history_rows.append(dict(epoch=9,dev=syntax_audit(head,dev)))
        for epoch in (10,11):
            started=time.perf_counter();head.train();torch.manual_seed(4200+epoch)
            losses={'ud':[],'local':[]};seen={'ud':[],'local':[]}
            for step,(kind,indices) in enumerate(experiment['schedules'][arm][str(epoch)],1):
                batch=[(ud if kind=='ud' else annotations)[i] for i in indices]
                optimizer.zero_grad(set_to_none=True);words=features.online(batch)
                lengths=torch.tensor([len(r['words']) for r in batch])
                mask=torch.arange(words.shape[1])[None]<lengths[:,None]
                if kind=='ud':
                    mask,parents,relations=ud_targets(batch,words.shape[1],RELATIONS)
                    arcs,labels=head(words,mask,gold_heads=parents)
                    loss=loss_for(arcs,labels,parents,relations,mask)
                else:
                    arcs,labels=head(words,mask);loss=structure_loss(arcs,labels,batch,RELATIONS)
                assert torch.isfinite(loss);loss.backward()
                if step==1:
                    assert any(p.grad is not None and p.grad.abs().sum()>0 for p in adapter_params)
                    assert all(p.grad is None for p in model.parameters() if not p.requires_grad)
                torch.nn.utils.clip_grad_norm_(parameters,5.0,error_if_nonfinite=True);optimizer.step()
                losses[kind].append(loss.item());seen[kind]+=indices
                if step%25==0:print(arm,epoch,step,kind,float(loss),flush=True)
            assert sorted(seen['ud'])==list(range(len(ud))) and sorted(seen['local'])==list(range(len(annotations)))
            save(epoch)
            history_rows.append(dict(epoch=epoch,loss={k:sum(v)/len(v) for k,v in losses.items()},examples_seen={k:len(v) for k,v in seen.items()},seconds=time.perf_counter()-started,dev=syntax_audit(head,dev)))
            write_json(out/f'{arm}-history.json',history_rows)
        # The primary endpoint is always epoch11, even if dev LAS regresses.
        assert history_rows[-1]['epoch']==11
        epochs[arm]=dict(primary_epoch=11,syntax_best_epoch=max(history_rows,key=lambda r:r['dev']['syntax']['all']['las'])['epoch'])
        evaluation[arm]=dict(epoch=11,syntax_dev=history_rows[-1]['dev'],english_dev=syntax_audit(head,english_dev),repair_audit=syntax_audit(head,selected['audit']))
        write_json(out/f'{arm}-history-probes.json',probe(head,features.cache(history)))
        write_json(out/f'{arm}-history83.json',history_audit(head,features,templates,cases))
        for name,rows,scope in [('v3-heldout',holdout,'Frozen unseen v3 template/recording-group weak holdout; fixed epoch11'),('v2-heldout',old_holdout,'Previously scored v2 holdout; old diagnostic only'),('old45',old45,'Previously exposed English training diagnostic in both arms')]:
            audit=local_audit(head,rows,scope)
            write_json(out/f'{arm}-{name}-structure-audit.json',audit)
            evaluation[arm][name]={k:v for k,v in audit.items() if k!='predictions'}
        set_adapters(model.model,False);logits=mask_probe(model,tokenizer)
        parity[arm]=dict(base_weights_unchanged=original_hash==base_hash(model),disabled_mlm_logits_exact=torch.equal(original_logits,logits),max_logit_difference=(original_logits-logits).abs().max().item())
        assert parity[arm]['base_weights_unchanged'] and parity[arm]['disabled_mlm_logits_exact']
        set_adapters(model.model,True)
        write_json(out/'evaluation.json',evaluation);write_json(out/'parity.json',parity);write_json(out/'epochs.json',epochs)
        del optimizer,head
    # Every captured dataset, source and old checkpoint remains immutable.
    assert all(digest(path)==sha for path,sha in hashes.items()),'source mutated during experiment'
    checkpoint_hashes={str(p):digest(p) for p in sorted(out.glob('*-epoch*.pt'))}
    write_json(out/'output-checkpoint-sha256.json',checkpoint_hashes)
    print('DONE',json.dumps(dict(epochs=epochs,parity=parity)),flush=True)

if __name__=='__main__':main()
