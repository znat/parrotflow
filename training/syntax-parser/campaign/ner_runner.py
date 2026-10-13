"""NER execution is gated on a separately reviewed multilingual input corpus."""
import copy
import random
from pathlib import Path
from campaign.common import *
from campaign.ner import load_corpus,normalize_row


def ner_view(row,mode):
    if mode=='original':return copy.deepcopy(row)
    result=copy.deepcopy(row);text=row['text']
    if mode=='lowercase':
        bounds=[0]
        for c in text:bounds.append(bounds[-1]+len(c.lower()))
        result['text']=''.join(c.lower() for c in text)
        for key in ('spans','unknown_spans'):
            for span in result.get(key,[]):span['start'],span['end']=bounds[span['start']],bounds[span['end']]
    else:
        require(mode=='punctuation_reduced','Invalid NER view')
        if not text.endswith('.') or any(s['end']==len(text) for s in row['spans']+row.get('unknown_spans',[])):
            result['augmentation_rejected']='No safely removable period';return result
        shortened=text[:-1].rstrip()
        if any(s['end']>len(shortened) for s in row['spans']+row.get('unknown_spans',[])):
            result['augmentation_rejected']='Removed suffix overlaps annotation';return result
        result['text']=shortened
    result=normalize_row(result);result['augmentation']=mode
    return result


def prepare_ner(source,output):
    from transformers import AutoTokenizer
    output=Path(output);require(not output.exists(),'New NER output required')
    rows=load_corpus(source);cfg=read('config.json')
    tok=AutoTokenizer.from_pretrained(cfg['model_id'],revision=cfg['model_revision'],local_files_only=True)
    protected={normalized(r['text']) for r in rows if r['split']!='train'}
    train=[r for r in rows if r['split']=='train'];aug=[];lookup={}
    for i,r in enumerate(train):
        for mode in ('original','lowercase','punctuation_reduced'):
            v=ner_view(r,mode)
            require(normalized(v['text']) not in protected,'NER augmentation crosses splits')
            lookup[i,mode]=len(aug);aug.append(v)
    for r in rows+aug:
        encoded=tok(r['words'],is_split_into_words=True,truncation=False)
        require(len(encoded['input_ids'])<=256,'Overlength NER input')
        require(set(x for x in encoded.word_ids() if x is not None)==set(range(len(r['words']))),'NER alignment')
    orders={}
    for seed in (42,43):
        orders[str(seed)]={}
        for epoch in range(1,6):
            rng=random.Random(seed*1000+epoch)
            groups={l:[i for i,r in enumerate(train) if r['language']==l] for l in LANGUAGES}
            size=max(len(v) for v in groups.values());batches={}
            for l,ids in groups.items():
                repeated=[]
                while len(repeated)<size:
                    cycle=ids.copy();rng.shuffle(cycle);repeated+=cycle
                chosen=[lookup[i,rng.choice(['original','original','lowercase','punctuation_reduced'])] for i in repeated[:size]]
                batches[l]=[chosen[i:i+16] for i in range(0,size,16)]
            orders[str(seed)][str(epoch)]=[dict(source='ner',indices=batches[l][i],view='original',language=l) for i in range(len(batches['en'])) for l in LANGUAGES]
    output.mkdir()
    for split in ('train','dev','confirmation'):write(output/(split+'.json'),[r for r in rows if r['split']==split])
    write(output/'train-views.json',aug);write(output/'orders.json',orders)
    write(output/'protocol.json',dict(source=str(source),source_sha256=sha(source),reviewed_corpus=True,updates_per_epoch=len(orders['42']['1']),balance='Equal sentence exposures per language, cycling smaller training pools',types=TYPES,threshold='Argmax BIO; no post-hoc confidence search',extension='Both seeds macro typed F1 epoch3-epoch2 >=.005; no language loss >.01; no language negative-rate increase'))
    write(output/'manifest.json',dict(files={p.name:sha(p) for p in output.glob('*.json')}))


def train_ner(data,ner_data,output,device):
    from campaign.cli import bundle,drop
    from campaign.network import Package
    from campaign.training import run_epochs,implementation_hash
    d,protocol,vocab,bhash=bundle(data);nd=Path(ner_data);verify_bundle(nd)
    output=Path(output);output.mkdir(parents=True,exist_ok=True)
    key=fingerprint(dict(syntax_data=bhash,ner_data=sha(nd/'manifest.json')))
    lock=dict(bundle_hash=key,implementation_hash=implementation_hash(),device=device)
    if (output/'run-lock.json').exists():require(read(output/'run-lock.json')==lock,'NER run changed')
    else:write(output/'run-lock.json',lock)
    pools={'ner':read(nd/'train-views.json')};dev=read(nd/'dev.json');orders=read(nd/'orders.json');decisions=[]
    for seed in (42,43):
        pkg=Package('ner',protocol,vocab,seed,device)
        run_epochs(pkg,output/f'N-seed{seed}',orders[str(seed)],pools,dev,set(),[1,2,3],key)
        before=read(output/f'N-seed{seed}/epoch2-evaluation.json')['metrics'];after=read(output/f'N-seed{seed}/epoch3-evaluation.json')['metrics']
        deltas=[(after[l]['typed_f1'] or 0)-(before[l]['typed_f1'] or 0) for l in LANGUAGES]
        decisions.append(sum(deltas)/3>=.005 and min(deltas)>=-.01 and all(after[l]['negative_rate']<=before[l]['negative_rate'] for l in LANGUAGES))
        del pkg;drop()
    extension=all(decisions)
    if extension:
        for seed in (42,43):
            pkg=Package('ner',protocol,vocab,seed,device)
            run_epochs(pkg,output/f'N-seed{seed}',orders[str(seed)],pools,dev,set(),[4,5],key)
            del pkg;drop()
    write(output/'NER-decision.json',dict(extension=extension,per_seed=decisions,endpoint=5 if extension else 3,confirmation_evaluated=False))


def confirm_ner(data,ner_data,output,device):
    import torch
    from campaign.cli import bundle,drop
    from campaign.network import Package
    from campaign.training import restore,implementation_hash
    from campaign.metrics import evaluate
    d,protocol,vocab,bhash=bundle(data);nd=Path(ner_data);verify_bundle(nd);output=Path(output)
    key=fingerprint(dict(syntax_data=bhash,ner_data=sha(nd/'manifest.json')))
    require(read(output/'run-lock.json')==dict(bundle_hash=key,implementation_hash=implementation_hash(),device=device),'NER confirmation run mismatch')
    decision=read(output/'NER-decision.json');epoch=decision['endpoint']
    require(epoch in (3,5),'Invalid NER endpoint')
    for seed in (42,43):
        path=output/f'N-seed{seed}/epoch{epoch}.pt'
        require(path.is_file(),f'Missing endpoint checkpoint: {path}')
    rows=read(nd/'confirmation.json');results={}
    marker=output/'NER-confirmation-consumed.json'
    with marker.open('x') as f:f.write('{"status":"started","no_automatic_retry":true}\n')
    for seed in (42,43):
        pkg=Package('ner',protocol,vocab,seed,device)
        state=torch.load(output/f'N-seed{seed}/epoch{epoch}.pt',map_location='cpu',weights_only=True)
        require(state['meta']['complete'] and state['meta']['epoch']==epoch and not state['meta']['smoke'],'Incomplete NER endpoint')
        restore(pkg,state,restore_rng=False);result=evaluate(pkg,rows)
        write(output/f'NER-confirmation-seed{seed}.json',result);results[str(seed)]=result['metrics']
        del pkg;drop()
    write(marker,dict(status='complete',endpoint=epoch,metrics=results,no_tuning_on_confirmation=True))
