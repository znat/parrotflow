"""Resume the verified syntax-only LoRA model for fixed epochs 3–5."""
import argparse
import os
import time
from pathlib import Path
os.environ.setdefault('HF_HOME', str(Path('artifacts/hf-cache').resolve()))
os.environ.setdefault('HF_HUB_OFFLINE', '1')
os.environ.setdefault('TOKENIZERS_PARALLELISM', 'false')
import torch
from transformers import AutoModelForMaskedLM, AutoTokenizer
from adapters import install_adapters, adapter_state, load_adapter_state, set_adapters
from adapter_pilot import mask_probe
from data import RELATIONS, write_json
from english_diversity_pilot import read, digest, ud_targets
from lora_syntax_only import OnlineFeatures, base_hash, load_groups, sync
from model import ParserHead, decode, loss_for
from probe_lora_trees import tree
from train import evaluate


def assert_state_equal(actual, expected):
    """Reject a reset optimizer or changed moment/counter, including nested state."""
    if torch.is_tensor(expected):
        assert torch.is_tensor(actual) and torch.equal(actual.detach().cpu(), expected.detach().cpu())
    elif isinstance(expected, dict):
        assert actual.keys() == expected.keys()
        for key in expected: assert_state_equal(actual[key], expected[key])
    elif isinstance(expected, (list, tuple)):
        assert len(actual) == len(expected)
        for a,b in zip(actual,expected): assert_state_equal(a,b)
    else:
        assert actual == expected, (actual, expected)


@torch.no_grad()
def assess(head, online, groups, device):
    head.eval()
    return {name: evaluate(head, online.cache(groups[name]), 16, device)
            for name in ('dev','english_dev','gum_dev')}


@torch.inference_mode()
def qualitative(head, online, rows):
    head.eval(); results=[]
    for row in rows:
        words=row['words']; features=online([{'words':words}])
        mask=torch.ones(features.shape[:2],dtype=torch.bool,device=features.device)
        arcs,labels=head(features,mask)
        parents,relations=decode(arcs[0],labels[0],len(words),RELATIONS)
        results.append({'text':row['text'],'words':words,'heads':parents,'labels':relations,
                        'tree':tree(words,parents,relations)})
    return results


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent',type=Path,default=Path('artifacts/lora-syntax-only-v1'))
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--device',default='mps')
    args=ap.parse_args(); out=args.output; parent=args.parent
    assert not out.exists(), 'Never overwrite experiments'
    if args.device=='mps':assert torch.backends.mps.is_available()
    torch.set_num_threads(4); torch.manual_seed(42); started=time.perf_counter()
    previous=read(parent/'protocol.json'); verified=read(parent/'verification.json')
    assert previous['epochs']==2 and previous['batch_size']==16 and previous['device']==args.device
    assert previous['local_training_rows']==0 and previous['lora']=={'blocks':11,'rank':4,'alpha':8,'targets':['Wqkv','Wo'],'initialization':'A Kaiming, B zero'}
    assert verified['encoder_before_sha256']==verified['encoder_after_sha256']
    assert verified['disabled_mlm_logits_exact_fresh_cpu'] and verified['sources_unchanged']
    for path,expected in previous['source_sha256'].items(): assert digest(path)==expected,path
    for name in ('lora-epoch2-resume.pt','lora-epoch2-weights.pt'):
        assert digest(parent/name)==verified['checkpoint_sha256'][name]
    groups,sources=load_groups()
    assert {k:len(v) for k,v in groups.items()}==previous['data_counts']
    probe_path=Path('artifacts/lora-tree-probe-v1/results.json'); probe_rows=read(probe_path)
    probe_protocol=read(probe_path.parent/'protocol.json')
    assert probe_protocol['checkpoints']['compact_lora']['sha256']==digest(parent/'lora-epoch2-weights.pt')
    assert len(probe_rows)==15
    config=read('config.json')
    sources += [Path(__file__),Path('tests/test_lora_syntax_continue.py'),Path('lora_syntax_only.py'),
                Path('adapters.py'),Path('model.py'),Path('train.py'),Path('data.py'),Path('config.json'),
                Path('adapter_pilot.py'),Path('english_diversity_pilot.py'),Path('probe_lora_trees.py'),
                parent/'protocol.json',parent/'verification.json',parent/'history.json',
                parent/'lora-epoch2-resume.pt',parent/'lora-epoch2-weights.pt',probe_path,probe_path.parent/'protocol.json']
    orders={epoch:torch.randperm(len(groups['ud']),generator=torch.Generator().manual_seed(4200+epoch)).tolist() for epoch in (3,4,5)}
    protocol={'parent':str(parent),'epochs':[3,4,5],'fixed_endpoint':5,'device':args.device,'batch_size':16,
        'task':previous['task'],'head':previous['head'],'lora':previous['lora'],'optimizer':previous['optimizer'],
        'optimizer_restore':'Exact epoch2 saved AdamW moments, parameter groups and counters; no reset',
        'seed_schedule':'torch.manual_seed(4200+epoch); row permutation from independent Generator with same seed',
        'data_counts':{k:len(v) for k,v in groups.items()},'local_training_rows':0,'sample_orders':orders,
        'evaluation':'same gold-word English UD development groups, each epoch; baseline epoch2 exact metrics replay required',
        'qualitative':'same15 saved sentences; fresh CPU inference at epochs2–5 after training; no deletion, no aggregate repair accuracy',
        'mlm_verification':'Unchanged full base hash plus fresh CPU backbone loaded with trained adapters disabled; avoid known CPU/MPS roundtrip bit-equality artifact',
        'model_id':config['model_id'],'model_revision':config['model_revision'],
        'source_sha256':{str(p):digest(p) for p in sources}}
    out.mkdir(parents=True); write_json(out/'protocol.json',protocol)
    print('PROTOCOL_FROZEN',digest(out/'protocol.json'),flush=True)
    tokenizer=AutoTokenizer.from_pretrained(config['model_id'],revision=config['model_revision'],local_files_only=True)
    def fresh_model():
        return AutoModelForMaskedLM.from_pretrained(config['model_id'],revision=config['model_revision'],
                   local_files_only=True,attn_implementation='eager').eval().requires_grad_(False)
    lm=fresh_model(); original_hash=base_hash(lm); original_logits=mask_probe(lm,tokenizer)
    assert original_hash==verified['encoder_before_sha256']
    install_adapters(lm.model); lm.to(args.device)
    saved=torch.load(parent/'lora-epoch2-resume.pt',map_location='cpu',weights_only=True)
    checkpoint=saved['weights']
    assert_state_equal(checkpoint,torch.load(parent/'lora-epoch2-weights.pt',map_location='cpu',weights_only=True))
    assert checkpoint['epoch']==2 and checkpoint['settings']==previous['head']
    assert checkpoint['protocol_sha256']==digest(parent/'protocol.json')
    load_adapter_state(lm.model,checkpoint['adapters']); set_adapters(lm.model,True)
    head=ParserHead(**checkpoint['settings']).to(args.device); head.load_state_dict(checkpoint['head'],strict=True)
    assert_state_equal(head.state_dict(),checkpoint['head']); assert_state_equal(adapter_state(lm.model),checkpoint['adapters'])
    head_params=list(head.parameters()); adapter_params=[p for p in lm.parameters() if p.requires_grad]
    params=head_params+adapter_params
    optimizer=torch.optim.AdamW([{'params':head_params,'lr':.001},{'params':adapter_params,'lr':.0001}],weight_decay=.01)
    optimizer.load_state_dict(saved['optimizer']); assert_state_equal(optimizer.state_dict(),saved['optimizer'])
    initial_steps=sorted({int(s['step'].item()) for s in optimizer.state.values()})
    assert initial_steps==[2996],initial_steps
    del saved,checkpoint
    online=OnlineFeatures(tokenizer,lm,args.device)
    replay=assess(head,online,groups,args.device); write_json(out/'resumed-epoch2-evaluation.json',replay)
    assert replay==read(parent/'history.json')['lora'][-1]['metrics'],'Epoch2 replay differs'
    write_json(out/'restore-verification.json',{'optimizer_restored_exact':True,'initial_optimizer_steps':initial_steps,
               'head_and_adapters_restored_exact':True,'baseline_metrics_replayed_exact':True})
    print('BASELINE_REPLAY_EXACT',flush=True)
    history=[]
    for epoch in (3,4,5):
        head.train(); torch.manual_seed(4200+epoch); sync(args.device); epoch_start=time.perf_counter(); losses=[]; seen=[]
        for step,start in enumerate(range(0,len(orders[epoch]),16),1):
            indices=orders[epoch][start:start+16]; seen+=indices; rows=[groups['ud'][i] for i in indices]
            optimizer.zero_grad(set_to_none=True); values=online(rows)
            mask,parents,relations=[v.to(args.device) for v in ud_targets(rows,values.shape[1],RELATIONS)]
            arcs,labels=head(values,mask,gold_heads=parents); loss=loss_for(arcs,labels,parents,relations,mask)
            assert torch.isfinite(loss); loss.backward()
            if step==1:
                assert any(p.grad is not None and p.grad.abs().sum()>0 for p in adapter_params)
                assert all(p.grad is None for p in lm.parameters() if not p.requires_grad)
            torch.nn.utils.clip_grad_norm_(params,5,error_if_nonfinite=True); optimizer.step(); losses.append(loss.item())
            if step%100==0:print('TRAIN',epoch,step,'/1498','loss',sum(losses)/len(losses),'seconds',time.perf_counter()-epoch_start,flush=True)
        assert sorted(seen)==list(range(len(groups['ud'])))
        assert sorted({int(s['step'].item()) for s in optimizer.state.values()})==[1498*epoch]
        sync(args.device); training_seconds=time.perf_counter()-epoch_start
        weights={'head':{k:v.detach().cpu() for k,v in head.state_dict().items()},'settings':head.settings,
                 'adapters':adapter_state(lm.model),'epoch':epoch,'protocol_sha256':digest(out/'protocol.json')}
        torch.save(weights,out/f'lora-epoch{epoch}-weights.pt')
        torch.save({'weights':weights,'optimizer':optimizer.state_dict()},out/f'lora-epoch{epoch}-resume.pt')
        eval_start=time.perf_counter(); metrics=assess(head,online,groups,args.device)
        record={'epoch':epoch,'loss':sum(losses)/len(losses),'training_seconds':training_seconds,
                'evaluation_seconds':time.perf_counter()-eval_start,'rows_seen_once':len(seen),'metrics':metrics}
        history.append(record); write_json(out/'history.json',history)
        print('EVAL',epoch,{name:{m:r['all'][m] for m in ('uas','las')} for name,r in metrics.items()},flush=True)
    final_base_hash=base_hash(lm); assert final_base_hash==original_hash
    # Fresh CPU construction is intentional: moving a model MPS→CPU introduces
    # tiny numerical changes even without training in this local runtime.
    del optimizer,params,adapter_params,head_params,online,head,lm
    if args.device=='mps':torch.mps.empty_cache()
    lm=fresh_model(); install_adapters(lm.model); online=OnlineFeatures(tokenizer,lm,'cpu')
    probe_results={}
    for epoch in (2,3,4,5):
        path=(parent if epoch==2 else out)/f'lora-epoch{epoch}-weights.pt'
        checkpoint=torch.load(path,map_location='cpu',weights_only=True)
        load_adapter_state(lm.model,checkpoint['adapters']); set_adapters(lm.model,True)
        head=ParserHead(**checkpoint['settings']); head.load_state_dict(checkpoint['head']); head.eval()
        probe_results[str(epoch)]=qualitative(head,online,probe_rows)
        if epoch==2:
            for pred,old in zip(probe_results['2'],probe_rows):
                assert {k:pred[k] for k in ('heads','labels','tree')}==old['predictions']['compact_lora']
        write_json(out/f'epoch{epoch}-qualitative-trees.json',probe_results[str(epoch)])
    set_adapters(lm.model,False)
    assert torch.equal(mask_probe(lm,tokenizer),original_logits)
    assert base_hash(lm)==original_hash
    for path,expected in protocol['source_sha256'].items():assert digest(path)==expected,path
    verification={'baseline_metrics_replayed_exact':True,'optimizer_restored_exact':True,'initial_optimizer_steps':initial_steps,
        'epoch2_cpu_probe_replayed_exact':True,'encoder_before_sha256':original_hash,'encoder_after_sha256':final_base_hash,
        'fresh_cpu_disabled_adapter_mlm_exact':True,'source_hashes_unchanged':True,'local_training_rows':0,
        'rows_seen_once_each_epoch':{r['epoch']:r['rows_seen_once'] for r in history},
        'total_wall_seconds':time.perf_counter()-started,'checkpoints':{p.name:digest(p) for p in out.glob('*.pt')},
        'qualitative_sha256':{p.name:digest(p) for p in out.glob('*-qualitative-trees.json')}}
    write_json(out/'verification.json',verification); print('COMPLETE',verification['total_wall_seconds'],flush=True)


if __name__=='__main__':main()
