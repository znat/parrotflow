from collections import Counter,defaultdict
import random
import torch
from campaign.common import *
from campaign.network import grammar_targets
from campaign.surface import input_only
from campaign.repair import repair,score
from campaign.ner import decode as decode_ner,counts as ner_counts
from campaign.trees import ud_targets
from campaign.parser import decode
from campaign.trees import RELATIONS


def f1(c,prefix=''):
    """Calculate count-based F1, leaving unsupported denominators undefined."""
    a,b,cnt=(c.get(prefix+k,0) for k in ('tp','fp','fn'))
    return 2*a/(2*a+b+cnt) if 2*a+b+cnt else None


def summarize(c,task):
    """Derive task metrics from additive per-row counters."""
    d=dict(c)
    if task=='syntax':
        d['las']=c.get('las_correct',0)/max(c.get('tokens',0),1)
        d['uas']=c.get('uas_correct',0)/max(c.get('tokens',0),1)
        for key,num,den in [('repair_precision','repair_correct','repair_predicted'),('repair_recall','repair_correct','repair_gold')]:d[key]=c.get(num,0)/c[den] if c.get(den) else None
        den=c.get('repair_predicted',0)+c.get('repair_gold',0)
        d['repair_f1']=2*c.get('repair_correct',0)/den if den else None
    elif task=='grammar':
        d['upos_accuracy']=c.get('upos_correct',0)/max(c.get('upos_total',0),1)
        d['bundle_exact']=c.get('bundle_correct',0)/max(c.get('bundle_total',0),1)
        d['positive_f1']=f1(c)
        d['seven_positive_f1']=f1(c,'seven_')
    else:
        d['typed_f1']=f1(c);d['span_f1']=f1(c,'span_')
        d['negative_rate']=c.get('negative_fp',0)/max(c.get('negative_rows',0),1)
    return d


@torch.inference_mode()
def evaluate(package,rows):
    """Save predictions and task/safety counts without using gold repair hints."""
    package.head.eval();totals=defaultdict(Counter);predictions=[]
    for start in range(0,len(rows),16):
        batch=rows[start:start+16];x=package.features(batch)
        if package.task=='syntax':
            mask,_,_=[t.to(package.device) for t in ud_targets(batch,x.shape[1],RELATIONS)]
            arcs,rels=package.head(x,mask)
        else:logits=package.head(x)
        for i,r in enumerate(batch):
            n=len(r['words']);c=Counter();p=dict(id=r['id'],language=r['language'],treebank=r.get('treebank'),family_id=r.get('family_id'))
            if package.task=='syntax':
                c.update(tokens=0,uas_correct=0,las_correct=0)
                heads,labels=decode(arcs[i],rels[i],n,RELATIONS)
                for j,(h,l) in enumerate(zip(heads,labels)):
                    if not r.get('upos') or r['upos'][j]!='PUNCT':
                        c['tokens']+=1;c['uas_correct']+=int(h==r['heads'][j]);c['las_correct']+=int(h==r['heads'][j] and l==r['labels'][j])
                    c['repair_gold']+=int(r['labels'][j]=='reparandum');c['repair_predicted']+=int(l=='reparandum')
                    c['repair_correct']+=int(l==r['labels'][j]=='reparandum' and h==r['heads'][j])
                p.update(heads=heads,labels=labels)
                if 'intended_output' in r:
                    try:output=repair(input_only(r),heads,labels)
                    except ValueError:output=dict(text=r['text'],deleted_token_ids=[],error='alignment unavailable')
                    scored=score(r,output);p.update(output=output,deletion=scored)
                    for k,v in scored.items():c['deletion_'+k]+=int(v)
                    c['complete_repairs']+=int(scored['repair'] and scored['exact_output']);c['repair_rows']+=int(scored['repair'])
                    c['keep_rows']+=int(not scored['repair'])
            elif package.task=='grammar':
                pred={k:[package.vocab[k][j] for j in values[i,:n].argmax(-1).cpu().tolist()] for k,values in logits.items()}
                for j in range(n):
                    c['upos_total']+=1;c['upos_correct']+=int(pred['upos'][j]==r['upos'][j]);c['confusion/'+r['upos'][j]+'/'+pred['upos'][j]]+=1
                    correct=True;observed=False
                    for a in ATTRIBUTES:
                        if not r['morph_observed'][j][a]:continue
                        observed=True;g=r['morph'][j].get(a,ABSENT);v=pred[a][j]
                        correct&=g==v;c[a+'/total']+=1;c[a+'/correct']+=int(g==v)
                        c[a+'/unknown']+=int(g not in package.vocab[a])
                        increments=dict(tp=int(g==v and g!=ABSENT),fp=int(v!=ABSENT and v!=g),fn=int(g!=ABSENT and v!=g))
                        for k,value in increments.items():
                            c[k]+=value;c[a+'/'+k]+=value
                            if a!='Gender':c['seven_'+k]+=value
                    c['bundle_total']+=int(observed);c['bundle_correct']+=int(observed and correct)
                p['tags']=pred
            else:
                tags=[BIO[t] for t in logits[i,:n].argmax(-1).cpu().tolist()]
                spans=decode_ner(r,tags);c.update(ner_counts(r,spans));p.update(tags=tags,spans=spans)
                for typ in TYPES:
                    sub=dict(r,spans=[s for s in r['spans'] if s['type']==typ])
                    for k,v in ner_counts(sub,[s for s in spans if s['type']==typ]).items():c[typ+'/'+k]+=v
            p['counts']=dict(c);predictions.append(p)
            for group in ('all',r['language'],r.get('treebank'),r.get('family_id')):
                if group:totals[group].update(c)
    return dict(metrics={g:summarize(c,package.task) for g,c in totals.items()},predictions=predictions)


def paired_effect(control,feature,samples=1000):
    """Language-stratified paired sentence bootstrap; seed uncertainty is separate."""
    lookup={(r['language'],r['treebank'],r['id']):r for r in feature}
    groups=defaultdict(list);zero_token_rows=Counter()
    for c in control:
        k=(c['language'],c['treebank'],c['id']);f=lookup.pop(k)
        # Legacy Counter JSON omits zero fields on punctuation-only sentences.
        n=c['counts'].get('tokens',0)
        require(n==f['counts'].get('tokens',0),'Unpaired scoring masks')
        a,b=c['counts'].get('las_correct',0),f['counts'].get('las_correct',0)
        require(0<=a<=n and 0<=b<=n,'Invalid attachment counts')
        group=groups[c['language']]
        if n==0:
            zero_token_rows[c['language']]+=1
            continue
        # Zero-weight sentences carry no LAS evidence and can make a bootstrap
        # draw undefined. Condition resampling on scoreable sentences.
        group.append((a,b,n))
    require(not lookup,'Unpaired feature rows')
    require(groups and all(groups.values()),'Each language needs scored tokens')
    def delta(rows):
        """Calculate the paired LAS effect for a sentence resample."""
        return 100*sum(b-a for a,b,n in rows)/sum(n for a,b,n in rows)
    rng=random.Random(723);draws=[]
    effects={l:delta(v) for l,v in groups.items()}
    for _ in range(samples):draws.append(sum(delta(rng.choices(v,k=len(v))) for v in groups.values())/len(groups))
    draws.sort()
    return dict(per_language_pp=effects,macro_pp=sum(effects.values())/len(effects),macro_ci95_pp=[draws[int(.025*samples)],draws[min(samples-1,int(.975*samples))]],zero_token_rows=dict(zero_token_rows))


def select_feature(paired):
    """Select grammar fusion only when both paired effects satisfy the gate."""
    require(len(paired)==2,'Both seeds required')
    practical=sum(p['macro_pp'] for p in paired)/2>=.2 and all(p['macro_pp']>0 and min(p['per_language_pp'].values())>=-.5 for p in paired)
    supported=all(p['macro_ci95_pp'][0]>0 for p in paired)
    return dict(selected='feature' if practical and supported else 'context',status='supported' if practical and supported else 'inconclusive_or_failed',paired=paired)
