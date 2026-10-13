"""Reviewed five-type NER input contract, unknown-region masking and exact spans."""
import re
from collections import defaultdict
from campaign.common import *
TOKEN=re.compile(r"\w+(?:['’]\w+)*|[^\w\s]")


def normalize_row(row):
    r=dict(row);text=r['text'];matches=list(TOKEN.finditer(text))
    r['words']=[m.group() for m in matches];r['offsets']=[[m.start(),m.end()] for m in matches]
    target=[0]*len(matches);occupied=set();unknown=r.get('unknown_spans',[])
    require(r.get('annotation_complete') is True or unknown,'Partial annotations need explicit unknown regions')
    for s in r['spans']+unknown:
        require(type(s['start']) is int and type(s['end']) is int and 0<=s['start']<s['end']<=len(text),'Invalid NER span')
    for s in r['spans']:
        require(s['type'] in TYPES,'Unmapped entity type')
        ids=[i for i,(a,b) in enumerate(r['offsets']) if a>=s['start'] and b<=s['end']]
        require(ids and r['offsets'][ids[0]][0]==s['start'] and r['offsets'][ids[-1]][1]==s['end'],'Entity cuts token')
        require(not occupied.intersection(ids),'Overlapping entities')
        require(not any(s['start']<u['end'] and u['start']<s['end'] for u in unknown),'Positive overlaps unknown')
        for j,i in enumerate(ids):target[i]=BIO.index(('B-' if j==0 else 'I-')+s['type'])
        occupied.update(ids)
    for i,(a,b) in enumerate(r['offsets']):
        if any(a<u['end'] and u['start']<b for u in unknown):target[i]=-100
    r['ner_targets']=target
    return r


def load_corpus(path):
    rows=read(path);require(isinstance(rows,list),'NER corpus must be a list')
    groups=defaultdict(set);contents=defaultdict(set);ids=set();languages=defaultdict(set)
    result=[]
    for r in rows:
        require(r['language'] in LANGUAGES and r['split'] in ('train','dev','confirmation'),'NER language/split')
        require(r.get('reviewed') is True and r.get('review_provenance'),'NER rows require review provenance')
        require(r['id'] not in ids,'Duplicate NER ID');ids.add(r['id'])
        for field in ('group_id','source_id','template_id'):
            require(r.get(field),f'Missing NER {field}')
            groups[(field,r[field])].add(r['split'])
        for family in r.get('name_families',[]):groups['name_family',family].add(r['split'])
        require(not r['spans'] or r.get('name_families'),'Named examples require alias family locks')
        contents[normalized(r['text'])].add(r['split']);languages[r['split']].add(r['language'])
        result.append(normalize_row(r))
    require(all(len(v)==1 for v in groups.values()) and all(len(v)==1 for v in contents.values()),'NER split leakage')
    require(all(languages[s]==set(LANGUAGES) for s in ('train','dev','confirmation')),'NER needs each language in every split')
    return result


def decode(row, labels):
    spans=[];active=None
    for (a,b),tag in zip(row['offsets'],labels):
        if tag=='O':active=None;continue
        prefix,typ=tag.split('-',1)
        if prefix=='B' or active is None or active['type']!=typ:
            active=dict(start=a,end=b,type=typ);spans.append(active)
        else:active['end']=b
    return spans


def counts(row,predicted):
    unknown=row.get('unknown_spans',[])
    keep=lambda s:not any(s['start']<u['end'] and u['start']<s['end'] for u in unknown)
    pred={tuple(s[k] for k in ('start','end','type')) for s in predicted if keep(s)}
    gold={tuple(s[k] for k in ('start','end','type')) for s in row['spans']}
    pspan={x[:2] for x in pred};gspan={x[:2] for x in gold}
    return dict(tp=len(pred&gold),fp=len(pred-gold),fn=len(gold-pred),span_tp=len(pspan&gspan),span_fp=len(pspan-gspan),span_fn=len(gspan-pspan),negative_rows=int(not gold and not unknown),negative_fp=len(pred) if not gold and not unknown else 0)
