"""Explicit commands separate implementation smoke, campaign training and test exposure."""
import argparse
import copy
import gc
import json
import random
from pathlib import Path
import torch
from campaign.common import *
from campaign.dataset import prepare
from campaign.network import Package,Teacher
from campaign.training import run_epochs,capture,restore,save,implementation_hash
from campaign.metrics import evaluate,paired_effect,select_feature
from campaign.ner import load_corpus,normalize_row
from campaign.surface import input_only
from campaign.repair import repair,score


def bundle(path):
    path=Path(path);verify_bundle(path)
    return path,read(path/'protocol.json'),read(path/'inventories.json'),sha(path/'manifest.json')


def drop(*objects):
    gc.collect()
    if torch.backends.mps.is_available():torch.mps.empty_cache()


def smoke_rows():
    # Tiny authored examples solely for testing NER plumbing, not a reviewed corpus.
    result=[]
    for lang,text in [('en','Ana uses ToolX.'),('fr','Ana utilise ToolX.'),('es','Ana usa ToolX.')]:
        result.append(normalize_row(dict(id='fixture-'+lang,language=lang,text=text,annotation_complete=True,spans=[dict(start=0,end=3,type='person'),dict(start=text.index('ToolX'),end=text.index('ToolX')+5,type='product_tool')],provenance='smoke fixture only')))
    return result


def safety_examples():
    cases=[]
    for lang,cue in [('en','sorry'),('fr','pardon'),('es','perdón')]:
        for kind in ('repair','keep','negation'):
            if kind=='repair':text=f'red , {cue} , blue';words=['red',',',cue,',','blue'];heads=[5,3,5,3,0];labels=['reparandum','punct','discourse','punct','root'];target='blue'
            elif kind=='keep':text='red and blue';words=['red','and','blue'];heads=[0,3,1];labels=['root','cc','conj'];target=text
            else:text='not red blue';words=['not','red','blue'];heads=[2,3,0];labels=['advmod','reparandum','root'];target=text
            r=dict(language=lang,text=text,words=words,heads=heads,labels=labels)
            o=repair(input_only(r),heads,labels)
            require(o['text']==target,f'Safety fixture failed {lang}/{kind}')
            cases.append(dict(language=lang,kind=kind,input=text,output=o))
    return cases


def execute(data,output,device,smoke=False):
    d,protocol,vocab,bhash=bundle(data);output=Path(output)
    output.mkdir(parents=True,exist_ok=True)
    lock=dict(bundle_hash=bhash,implementation_hash=implementation_hash(),smoke=smoke,device=device)
    if (output/'run-lock.json').exists():require(read(output/'run-lock.json')==lock,'Run lock mismatch')
    else:write(output/'run-lock.json',lock)
    write(output/'scorer-preflight.json',safety_examples())
    pools={'ud':read(d/'ud.json'),'local':read(d/'local_train.json')}
    dev=read(d/'dev.json')+read(d/'gum.json')
    localdev=read(d/'local_dev.json');orders=read(d/'orders.json');forbidden=set(read(d/'forbidden.json'))
    seeds=[42] if smoke else [42,43]
    if smoke:
        dev=[next(r for r in pools['ud'] if r['language']==l) for l in LANGUAGES]
        localdev=[next(r for r in pools['local'] if r['language']==l and r['label']==label) for l in LANGUAGES for label in ('repair','keep')]
    g_end=1 if smoke else 5;s_screen=1 if smoke else 2
    grammar={};syntax={};paired=[]
    for seed in seeds:
        plans={str(e):orders[str(seed)][str(e)]['base'] for e in range(1,6)}
        pkg=Package('grammar',protocol,vocab,seed,device)
        grammar[seed]=run_epochs(pkg,output/f'G-seed{seed}',plans,pools,dev,forbidden,list(range(1,g_end+1)),bhash,smoke=smoke,max_batches=3 if smoke else None)
        del pkg;drop()
        for arm in ('context','feature'):
            teacher=Teacher(grammar[seed],protocol,vocab,seed,device,allow_smoke=smoke) if arm=='feature' else None
            pkg=Package('syntax',protocol,vocab,seed,device,arm=='feature',teacher)
            syntax[seed,arm]=run_epochs(pkg,output/f'S-{arm}-seed{seed}',plans,pools,dev,forbidden,list(range(1,s_screen+1)),bhash,smoke=smoke,max_batches=3 if smoke else None)
            del pkg,teacher;drop()
        if not smoke:
            c=read(output/f'S-context-seed{seed}/epoch2-evaluation.json')['predictions']
            f=read(output/f'S-feature-seed{seed}/epoch2-evaluation.json')['predictions']
            # GUM is a separate regression set, never part of the three-language macro.
            primary={(r['language'],r['treebank'],r['id']) for r in read(d/'dev.json')}
            paired.append(paired_effect([r for r in c if (r['language'],r['treebank'],r['id']) in primary],[r for r in f if (r['language'],r['treebank'],r['id']) in primary]))
    selection=dict(selected='feature',status='smoke exercises fusion, not selection') if smoke else select_feature(paired)
    write(output/'syntax-selection.json',selection);arm=selection['selected']
    parents={}
    for seed in seeds:
        teacher=Teacher(grammar[seed],protocol,vocab,seed,device,allow_smoke=smoke) if arm=='feature' else None
        if smoke:parent=syntax[seed,arm]
        else:
            pkg=Package('syntax',protocol,vocab,seed,device,arm=='feature',teacher)
            plans={str(e):orders[str(seed)][str(e)]['base'] for e in range(1,6)}
            parent=run_epochs(pkg,output/f'S-{arm}-seed{seed}',plans,pools,dev,forbidden,[3,4,5],bhash,resume=syntax[seed,arm])
            del pkg;drop()
        parents[seed]=str(parent)
        # Evaluate parent on the same ordinary + local development sets as H arms.
        pkg=Package('syntax',protocol,vocab,seed,device,arm=='feature',teacher)
        restore(pkg,torch.load(parent,map_location='cpu',weights_only=True))
        write(output/f'parent-seed{seed}-evaluation.json',evaluate(pkg,dev+localdev))
        del pkg;drop()
        for branch in ('mix','control'):
            pkg=Package('syntax',protocol,vocab,seed,device,arm=='feature',teacher)
            plans={str(e):orders[str(seed)][str(e)][branch] for e in (6,7)}
            if smoke:
                # Ensure both ordinary and inserted slots and all three views run.
                mixed=orders[str(seed)]['6']['mix'];actual=orders[str(seed)]['6'][branch]
                ids=[next(i for i,s in enumerate(mixed) if s['language']==l and s['source']==src) for l in LANGUAGES for src in ('ud','local')]
                plans['6']=[dict(actual[i],view=['original','lowercase','punctuation_reduced'][j%3]) for j,i in enumerate(ids)]
            result=run_epochs(pkg,output/f'H-{branch}-seed{seed}',plans,pools,dev+localdev,forbidden,[6] if smoke else [6,7],bhash,resume=parent,smoke=smoke,max_batches=6 if smoke else None)
            del pkg;drop()
        del teacher;drop()
    write(output/'parents.json',{str(k):v for k,v in parents.items()})
    if smoke:
        fixtures=smoke_rows();npools={'ner':fixtures};plans={'1':[dict(source='ner',indices=[i],view='original',language=LANGUAGES[i]) for i in range(3)]}
        pkg=Package('ner',protocol,vocab,42,device)
        run_epochs(pkg,output/'N-fixture-seed42',plans,npools,fixtures,set(),[1],bhash,smoke=True,max_batches=3)
        # CPU exact or documented tight MPS tolerance on identical restored state.
        from lora_syntax_continue import assert_state_equal
        before=capture(pkg,dict(epoch=1,cursor=0,complete=False,smoke=True,bundle_hash=bhash,backend=device))
        save(output/'resume-probe.pt',before);pkg.update(fixtures);after=capture(pkg,before['meta'])
        restore(pkg,torch.load(output/'resume-probe.pt',map_location='cpu',weights_only=True))
        assert_state_equal(before,capture(pkg,before['meta']))
        pkg.update(fixtures);replayed=capture(pkg,before['meta']);diff=[]
        def compare(a,b):
            if torch.is_tensor(a):
                a,b=a.cpu(),b.cpu();delta=float((a.double()-b.double()).abs().max()) if a.numel() else 0
                if delta:diff.append(delta)
                require(torch.allclose(a,b,rtol=1e-6 if device=='mps' else 0,atol=1e-7 if device=='mps' else 0),'Replay outside declared tolerance')
            elif isinstance(a,dict):
                require(a.keys()==b.keys(),'Replay keys')
                for k in a:compare(a[k],b[k])
            elif isinstance(a,(list,tuple)):
                require(len(a)==len(b),'Replay lengths')
                for x,y in zip(a,b):compare(x,y)
            else:require(a==b,'Replay metadata')
        compare(after,replayed)
        write(output/'smoke-result.json',dict(passed=True,stages=['grammar','syntax_context','syntax_features','hesitation_mix','hesitation_control','NER_fixture'],replay_max_abs=max(diff,default=0),exact_replay=not diff,heldout_evaluation=False,NER_data_ready=False))
    else:
        primary={(r['language'],r['treebank'],r['id']) for r in read(d/'dev.json')}
        hgate=h_decision(output,seeds,primary)
        write(output/'H-decision.json',hgate)
        write(output/'campaign-status.json',dict(training_complete=True,COSER_evaluated=False,NER='separate reviewed-data gate',H=hgate))


def h_decision(output,seeds,primary):
    results=[]
    for seed in seeds:
        mix_result=read(output/f'H-mix-seed{seed}/epoch7-evaluation.json');control_result=read(output/f'H-control-seed{seed}/epoch7-evaluation.json')
        mix=mix_result['metrics'];control=control_result['metrics']
        parent=read(output/f'parent-seed{seed}-evaluation.json')['metrics']
        # Equal aggregate harm counts can hide a newly broken KEEP sentence.
        old_harm={(p['language'],p['id']) for p in control_result['predictions'] if p.get('deletion',{}).get('harmful_keep')}
        new_harm=[dict(language=p['language'],id=p['id']) for p in mix_result['predictions'] if p.get('deletion',{}).get('harmful_keep') and (p['language'],p['id']) not in old_harm]
        deltas=[];safe=not new_harm
        for l in LANGUAGES:
            m,c=mix[l],control[l]
            deltas.append(m.get('complete_repairs',0)/max(m.get('repair_rows',0),1)-c.get('complete_repairs',0)/max(c.get('repair_rows',0),1))
            safe &= m.get('deletion_harmful_keep',0)<=c.get('deletion_harmful_keep',0) and m.get('deletion_latest_deleted',0)==0 and m.get('deletion_negation_deleted',0)==0
            # Match the original per-language primary dev gate; neither synthetic
            # all-token LAS nor the larger separate GUM set can dilute it.
            def las(result):
                subset=[p['counts'] for p in result['predictions'] if p['language']==l and (p['language'],p['treebank'],p['id']) in primary]
                require(subset,'Missing primary language evaluation')
                return sum(p['las_correct'] for p in subset)/sum(p['tokens'] for p in subset)
            safe &= las(mix_result)>=las(control_result)-.005
        natural=[]
        for tb in ('en_eslspok','en_gum','fr_rhapsodie','fr_parisstories'):
            if tb in mix:
                f=mix[tb]['repair_f1']
                natural.append(dict(treebank=tb,requires_analysis=any(f is not None and ref[tb]['repair_f1'] is not None and f<ref[tb]['repair_f1'] for ref in (parent,control))))
        results.append(dict(seed=seed,repair_gain=sum(deltas)/3,safety_pass=bool(safe),new_harmful_keep=new_harm,natural=natural))
    return dict(passed=all(r['repair_gain']>0 and r['safety_pass'] and not any(x['requires_analysis'] for x in r['natural']) for r in results),seeds=results,scope='Development screen; COSER and real dictation confirmation still pending')


def endpoint(data,run,device):
    d,protocol,vocab,bhash=bundle(data);run=Path(run)
    lock=read(run/'run-lock.json');require(not lock['smoke'] and lock['bundle_hash']==bhash and lock['implementation_hash']==implementation_hash(),'Only matching completed campaign can evaluate COSER')
    require((run/'campaign-status.json').exists(),'Complete campaign first')
    marker=run/'COSER-consumed.json'
    coser=Path('artifacts/data/es_coser-test.jsonl')
    require(sha(coser)==protocol['source_sha256'][str(coser)],'COSER source changed')
    rows=read(d/'coser-endpoint-only.json')
    arm=read(run/'syntax-selection.json')['selected'];all_results={}
    require(arm in ('context','feature'),'Invalid selected syntax arm')
    for seed in (42,43):
        paths=[run/f'S-{arm}-seed{seed}/epoch5.pt',run/f'H-control-seed{seed}/epoch7.pt',run/f'H-mix-seed{seed}/epoch7.pt']
        if arm=='feature':paths.append(run/f'G-seed{seed}/epoch5.pt')
        for path in paths:require(path.is_file(),f'Missing endpoint checkpoint: {path}')
    # Reserve only after read-only prerequisites pass; failures after reservation
    # remain marked because predictions may already have exposed the heldout set.
    with marker.open('x') as f:json.dump(dict(status='started',no_automatic_retry=True),f)
    for seed in (42,43):
        teacher=Teacher(run/f'G-seed{seed}/epoch5.pt',protocol,vocab,seed,device) if arm=='feature' else None
        for name,path in [('parent',run/f'S-{arm}-seed{seed}/epoch5.pt'),('control',run/f'H-control-seed{seed}/epoch7.pt'),('mix',run/f'H-mix-seed{seed}/epoch7.pt')]:
            pkg=Package('syntax',protocol,vocab,seed,device,arm=='feature',teacher)
            state=torch.load(path,map_location='cpu',weights_only=True);require(state['meta']['complete'] and not state['meta']['smoke'],'Invalid endpoint')
            restore(pkg,state,restore_rng=False)
            # Explicit rejection instead of truncation; denominator changes prohibited.
            result=evaluate(pkg,rows);write(run/f'COSER-{name}-seed{seed}.json',result)
            all_results[f'{name}-{seed}']=result['metrics']['all'];del pkg;drop()
        del teacher;drop()
    veto=any(all_results[f'mix-{s}']['las']<all_results[f'{ref}-{s}']['las']-.005 or (all_results[f'mix-{s}']['repair_f1'] or 0)<(all_results[f'{ref}-{s}']['repair_f1'] or 0) for s in (42,43) for ref in ('parent','control'))
    write(marker,dict(status='complete',veto=veto,results=all_results,policy='No further tuning on COSER'))


def main():
    ap=argparse.ArgumentParser();sub=ap.add_subparsers(dest='command',required=True)
    p=sub.add_parser('prepare');p.add_argument('--output',required=True)
    for command in ('smoke','train','coser-endpoint'):
        p=sub.add_parser(command);p.add_argument('--data',required=True);p.add_argument('--output',required=True);p.add_argument('--device',choices=['cpu','mps'],default='cpu')
    p=sub.add_parser('ner-prepare');p.add_argument('--input',required=True);p.add_argument('--output',required=True)
    for command in ('ner-train','ner-confirmation'):
        p=sub.add_parser(command);p.add_argument('--data',required=True);p.add_argument('--ner-data',required=True);p.add_argument('--output',required=True);p.add_argument('--device',choices=['cpu','mps'],default='cpu')
    args=ap.parse_args();torch.set_num_threads(4)
    if getattr(args,'device',None)=='mps':require(torch.backends.mps.is_available(),'MPS unavailable')
    if args.command=='prepare':prepare(args.output)
    elif args.command=='coser-endpoint':endpoint(args.data,args.output,args.device)
    elif args.command=='ner-prepare':
        from campaign.ner_runner import prepare_ner
        prepare_ner(args.input,args.output)
    elif args.command in ('ner-train','ner-confirmation'):
        from campaign.ner_runner import train_ner,confirm_ner
        operation=train_ner if args.command=='ner-train' else confirm_ner
        operation(args.data,args.ner_data,args.output,args.device)
    else:execute(args.data,args.output,args.device,smoke=args.command=='smoke')

if __name__=='__main__':main()
