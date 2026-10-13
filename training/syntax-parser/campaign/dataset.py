"""Immutable data preparation, train-only feature inventories and frozen schedules."""
import copy
import json
import random
from collections import Counter, defaultdict
from pathlib import Path
from campaign.common import *
from campaign.surface import aligned_units
from data import RELATIONS, valid_tree


def parse_feats(value):
    result={}
    for item in (value or '').split('|'):
        if not item or item=='_':continue
        k,v=item.split('=',1)
        require(k not in result,'Repeated morphology key')
        result[k]=','.join(sorted(v.split(',')))
    return result


def inventories(rows):
    return {'upos':UPOS, **{a:[ABSENT]+sorted({f[a] for r in rows for f,m in zip(r['morph'],r['morph_observed']) if m[a] and a in f}) for a in ATTRIBUTES}}


def make_orders(rows, local, seed, epoch):
    rng=random.Random(seed*1000+epoch)
    pools={l:[i for i,r in enumerate(rows) if r['language']==l] for l in LANGUAGES}
    ordinary={}
    for l,ids in pools.items():
        rng.shuffle(ids);ordinary[l]=[ids[i:i+16] for i in range(0,len(ids),16)]
    base=[dict(source='ud',indices=ordinary[l][i],view='original',language=l) for i in range(188) for l in LANGUAGES]
    require(len(base)==564,'Ordinary schedule changed')
    if epoch<=5:return {'base':base}
    per_lang={l:[] for l in LANGUAGES}
    for l in LANGUAGES:
        local_ids=[i for i,r in enumerate(local) if r['language']==l]
        expanded=[]
        while len(expanded)<336:
            cycle=local_ids.copy();rng.shuffle(cycle);expanded.extend(cycle)
        expanded=expanded[:336]
        slots=set(rng.sample(range(188),21));j=0
        for i,batch in enumerate(ordinary[l]):
            mode=rng.choice(['original','original','lowercase','punctuation_reduced'])
            per_lang[l].append((dict(source='ud',indices=batch,view=mode,language=l),None))
            if i in slots:
                mode=rng.choice(['original','original','lowercase','punctuation_reduced'])
                actual=dict(source='local',indices=expanded[j:j+16],view=mode,language=l)
                control=dict(source='ud',indices=[rng.choice(pools[l]) for _ in range(16)],view=mode,language=l)
                per_lang[l].append((actual,control));j+=16
        require(j==336 and len(per_lang[l])==209,'Local schedule mismatch')
    mix=[];control=[]
    for i in range(209):
        for l in LANGUAGES:
            a,b=per_lang[l][i];mix.append(a);control.append(b or a)
    return {'mix':mix,'control':control}


def prepare(output):
    from huggingface_hub import hf_hub_download
    from transformers import AutoTokenizer
    import pyarrow.parquet as pq
    output=Path(output);require(not output.exists(),'New output directory required')
    cfg=read('config.json');prior=Path('artifacts/multilingual-layer12-language-feature-v1')
    adjudicated=Path('artifacts/hesitation-multilingual-adjudicated-v1')
    protected={};sources={}
    for base in (prior,adjudicated):
        manifest=read(base/('protocol.json' if base==prior else 'manifest.json'))
        locks=manifest['data_files'] if base==prior else manifest['output_sha256']
        for name,h in locks.items():require(sha(base/name)==h,f'Changed input {base/name}')
        sources[str(base/('protocol.json' if base==prior else 'manifest.json'))]=sha(base/('protocol.json' if base==prior else 'manifest.json'))
    groups={k:read(prior/name) for k,name in [('ud','train.json'),('dev','dev.json'),('gum','gum-regression.json')]}
    for name in ['train.json','dev.json','gum-regression.json']:sources[str(prior/name)]=sha(prior/name)
    coverage={};rawlookup={}
    treebanks={r['treebank'] for rows in groups.values() for r in rows}
    needed={(r['treebank'],r['id']) for rows in groups.values() for r in rows}
    for tb in sorted(treebanks):
        for split in ('train','dev'):
            english=Path('artifacts/stanza-english-data')
            copied=english/f'sources/parquet/{tb}/{split}.parquet'
            if copied.exists():
                lock=read(english/'manifest.json')
                require(lock['revision']==cfg['dataset_revision'],'English source revision mismatch')
                require(sha(copied)==lock['source_sha256'][str(copied.relative_to(english))],'Changed English raw source')
                path=copied
            else:
                path=Path(hf_hub_download(cfg['dataset_id'],f'parquet/{tb}/{split}.parquet',repo_type='dataset',revision=cfg['dataset_revision'],cache_dir='artifacts/hf-cache/hub',local_files_only=True))
            sources[str(path)]=sha(path)
            raw=pq.read_table(path).to_pylist()
            if split=='train':
                coverage[tb]={a:any(a in parse_feats(f) for r in raw for f in r['feats']) for a in ATTRIBUTES}
            for r in raw:
                key=(tb,r['sent_id'])
                if key in needed:
                    require(key not in rawlookup,f'Duplicate raw ID {key}')
                    rawlookup[key]=(r,split)
    for name,rows in groups.items():
        for r in rows:
            raw,split=rawlookup[r['treebank'],r['id']]
            require(raw['tokens']==r['words'] and [int(x) for x in raw['head']]==r['heads'] and [x.split(':')[0] for x in raw['deprel']]==r['labels'] and raw['upos']==r['upos'],'Raw annotation mismatch')
            require(split==('train' if name=='ud' else 'dev'),'Official split mismatch')
            r.update(morph=[parse_feats(f) for f in raw['feats']],morph_observed=[coverage[r['treebank']].copy() for _ in raw['tokens']],official_split=split)
            try:r['surface_ud_map']=aligned_units(r)
            except ValueError:r['surface_alignment_unavailable']=True
    groups['local_train']=[];groups['local_dev']=[];groups['local_test']=[]
    for lang in LANGUAGES:
        for split in ('train','dev','test'):
            path=adjudicated/'syntax-candidates'/lang/(split+'.json');sources[str(path)]=sha(path)
            for r in read(path):
                require(r['syntax_training_eligible'] and r['assigned_split']==split and r['language']==lang,'Invalid local eligibility')
                aligned_units(r)
                groups['local_'+split].append(r)
    require([len(groups['local_'+x]) for x in ('train','dev','test')]==[688,152,168],'Local counts changed')
    families=defaultdict(set)
    for split in ('train','dev','test'):
        for r in groups['local_'+split]:families[r['family_id']].add(split)
    require(all(len(v)==1 for v in families.values()),'Family leakage')
    forbidden=set()
    # Protect every existing normalized official dev/test, including COSER data;
    # this reads labels/text for exclusion only, never runs model evaluation.
    for path in Path('artifacts/data').glob('*.jsonl'):
        if path.stem.endswith(('-dev','-test')):
            sources[str(path)]=sha(path)
            for line in path.read_text().splitlines():
                r=json.loads(line);forbidden.update([normalized(r['text']),normalized(' '.join(r['words']))])
    for name,rows in groups.items():
        if name not in ('ud','local_train'):
            for r in rows:
                forbidden.update([normalized(r['text']),normalized(' '.join(r['words']))])
                if r.get('intended_output'):forbidden.add(normalized(r['intended_output']))
    for name in ('ud','local_train'):
        for r in groups[name]:
            require(normalized(r['text']) not in forbidden and normalized(' '.join(r['words'])) not in forbidden,'Heldout collision')
            if r.get('intended_output'):require(normalized(r['intended_output']) not in forbidden,'Target heldout collision')
            require(valid_tree(r['heads']) and all(x in RELATIONS for x in r['labels']),'Invalid training tree')
    tok=AutoTokenizer.from_pretrained(cfg['model_id'],revision=cfg['model_revision'],local_files_only=True)
    coser_path=Path('artifacts/data/es_coser-test.jsonl')
    coser_rows=[json.loads(line) for line in coser_path.read_text().splitlines()]
    coser_eligible=[];coser_rejected=[]
    for r in coser_rows:
        tokens=tok(r['words'],is_split_into_words=True,truncation=False)
        if len(tokens['input_ids'])>256:coser_rejected.append(r['id'])
        else:coser_eligible.append(r)
    for rows in groups.values():
        for i in range(0,len(rows),128):
            batch=rows[i:i+128];encoded=tok([r['words'] for r in batch],is_split_into_words=True,truncation=False)
            for j,r in enumerate(batch):
                require(len(encoded['input_ids'][j])<=256,f'Overlength {r["id"]}; revise protocol, do not truncate')
                require(set(x for x in encoded.word_ids(j) if x is not None)==set(range(len(r['words']))),'Incomplete subwords')
    vocab=inventories(groups['ud'])
    orders={str(seed):{str(epoch):make_orders(groups['ud'],groups['local_train'],seed,epoch) for epoch in range(1,8)} for seed in (42,43)}
    stats={name:{l:dict(rows=sum(r['language']==l for r in rows),tokens=sum(len(r['words']) for r in rows if r['language']==l)) for l in LANGUAGES} for name,rows in groups.items()}
    protocol=dict(version=1,languages=list(LANGUAGES),seeds=[42,43],block=12,model=cfg['model_id'],revision=cfg['model_revision'],dataset_revision=cfg['dataset_revision'],batch_size=16,updates_before_ner=18552,
        stages=dict(G=[1,5],S_screen=[1,2],S_continue=[3,5],H=[6,7]),
        optimizer=dict(head_lr=.001,lora_lr=.0001,weight_decay=.01,betas=[.9,.999],eps=1e-8,clip=5),
        feature_gate=dict(mean_macro_las_pp=.2,positive_each_seed=True,max_language_loss_pp=.5,bootstrap_samples=1000,each_seed_macro_ci_lower_gt_zero=True,inconclusive='context'),
        coser_gate=dict(endpoint_only=True,positive_f1_no_decline=True,max_las_decline_pp=.5,compare=['epoch5_parent','H7_control'],failed='veto; no retuning on COSER'),
        h_gate=dict(repair_gain_both_seeds=True,max_language_las_loss_pp=.5,new_harmful_keep=0,latest_deleted=0,negation_deleted=0),
        source_sha256=sources,stats=stats,coverage=coverage,
        coser_eligibility=dict(total_rows=len(coser_rows),eligible_rows=len(coser_eligible),overlength_ids=coser_rejected,eligible_reparandum=sum(x=='reparandum' for r in coser_eligible for x in r['labels'])),
        caveats=['Reviewed local trees are weak syntax-only proposals.','COSER is never used for selection.','No reviewed multilingual NER corpus supplied; separate input gate.'])
    output.mkdir()
    for name,rows in groups.items():write(output/(name+'.json'),rows)
    write(output/'coser-endpoint-only.json',coser_eligible)
    write(output/'inventories.json',vocab);write(output/'orders.json',orders);write(output/'forbidden.json',sorted(forbidden));write(output/'protocol.json',protocol)
    for path,h in sources.items():require(sha(path)==h,f'Source changed during preparation: {path}')
    write(output/'manifest.json',dict(files={p.name:sha(p) for p in output.glob('*.json')},source_sha256=sources))
    return protocol
