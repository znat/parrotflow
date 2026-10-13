"""Offline multilingual predicted-tree deletion policy and separate gold scorer.

Only explicit forward reparandum arcs can authorize a deletion. Duplicate roles
and parataxis are candidates only. Source UD/surface alignment is supplied; this
module does not pretend to solve raw-ASR word segmentation.
"""
import re
from campaign.surface import aligned_units
from mechanical_tree_repair import valid_tree, descendants

NEGATION = {'not',"n't",'n’t','never','ne','n\'','n’','pas','jamais','ni','nunca','jamás','tampoco','sin','sans','without'}
CUES = {
 'en': {('no',),('sorry',),('no','i','mean'),('sorry','i','mean')},
 'fr': {('non',),('pardon',),('non','je','veux','dire'),('pardon','je','veux','dire')},
 'es': {('no',),('perdón',),('perdon',),('no','quiero','decir'),('perdón','quiero','decir')},
}


def lexical(word):
    return any(c.isalnum() for c in word)


def repair(inputs, heads, labels):
    text=inputs['text'];words=inputs['words'];base=dict(text=text,edits=[],deleted_token_ids=[],candidates=[],abstentions=[])
    if not valid_tree(words,heads,labels) or any((h==0)!=(r=='root') for h,r in zip(heads,labels)):
        return dict(base,error='invalid tree; input preserved')
    try: units=aligned_units(inputs)
    except (ValueError,KeyError,TypeError):return dict(base,error='invalid alignment; input preserved')
    owner={i:u for u in units for i in u['ud_token_ids']}
    lower=[w.casefold() for w in words]
    proposals=[]
    for a,(b,rel) in enumerate(zip(heads,labels),1):
        if rel=='parataxis':base['candidates'].append(dict(kind='parataxis',dep=a,head=b,action='abstain'))
        if rel!='reparandum':continue
        why=None
        earlier=descendants(a,heads)
        if b<=a or not earlier or max(earlier)>=b:why='not an earlier forward subtree'
        core={b};pending=[b]
        while pending:
            parent=pending.pop()
            for i,h in enumerate(heads,1):
                if h==parent and i not in earlier and i not in core and labels[i-1] not in {'reparandum','parataxis','discourse','punct'}:
                    core.add(i);pending.append(i)
        if why is None and min(core)<=max(earlier):why='latest constituent overlaps earlier material'
        if why is None:
            start=min(owner[i]['start'] for i in earlier);end=min(owner[i]['start'] for i in core)
            deleted={i for u in units if u['start']>=start and u['end']<=end for i in u['ud_token_ids']}
            if any(i not in earlier and lexical(words[i-1]) for i in range(min(earlier),max(earlier)+1)):
                why='discontinuous earlier constituent'
            if any(labels[i-1] in {'nsubj','csubj'} for i in earlier if i!=a):why='whole-clause deletion withheld'
            gap=sorted(deleted-earlier)
            gap_lex=tuple(lower[i-1] for i in gap if lexical(words[i-1]))
            if gap_lex and gap_lex not in CUES.get(inputs['language'],set()):why='unrecognized intervening material'
            # Broad negation protection, except an independently predicted discourse cue.
            for i in deleted:
                if lower[i-1] in NEGATION or (lower[i-1] in {'no','non'} and not (i in gap and labels[i-1]=='discourse')):
                    why='negation protection'
            if not earlier<=deleted or deleted&core:why='surface unit touches latest or cuts earlier subtree'
            if any(set(u['ud_token_ids'])&deleted and not set(u['ud_token_ids'])<=deleted for u in units):why='partial multiword unit'
            # Shared surface extent must never absorb retained members of a unit.
            if any((set(u['ud_token_ids'])&earlier) and not set(u['ud_token_ids'])<=earlier for u in units):why='earlier subtree splits surface unit'
            if why is None:proposals.append(dict(start=start,end=end,deleted=sorted(deleted),protected=sorted(core),dep=a,head=b))
        if why:base['abstentions'].append(dict(dep=a,head=b,reason=why))
    for i in range(len(words)):
        if labels[i] in {'obj','obl','xcomp','ccomp'}:
            for j in range(i+1,len(words)):
                if heads[i]==heads[j]!=0 and labels[i]==labels[j]:base['candidates'].append(dict(kind='parallel_role',dep=i+1,head=j+1,action='abstain'))
    accepted=[]
    for p in proposals:
        if any(p is not q and (p['start']<q['end'] and q['start']<p['end'] or set(p['deleted'])&set(q['protected'])) for q in proposals):
            base['abstentions'].append(dict(dep=p['dep'],reason='conflicting candidates'))
        else:accepted.append(p)
    result=text
    for p in sorted(accepted,key=lambda p:p['start'],reverse=True):result=result[:p['start']]+result[p['end']:]
    base.update(text=result,edits=accepted,deleted_token_ids=sorted({i for p in accepted for i in p['deleted']}))
    return base


def score(gold, output):
    """Gold annotations enter here only, after inference and deletion are complete."""
    deleted=set(output['deleted_token_ids']);lex={i for i,w in enumerate(gold['words'],1) if lexical(w)}
    latest=set(gold.get('latest_token_ids',[]))
    protected=set(gold.get('protected_negation_token_ids',[]))
    # Protect negation retained by the reference edit; cue 'no' isn't negation gold.
    allowed=set(gold.get('delete_token_ids',[]))
    protected|={i for i,w in enumerate(gold['words'],1) if (w.casefold() in NEGATION or w.casefold() in {'no','non'}) and i not in allowed}
    return dict(changed=output['text']!=gold['text'],repair=gold['label']=='repair',
        exact_output=output['text']==gold['intended_output'],
        harmful_keep=gold['label']=='keep' and output['text']!=gold['text'],
        latest_deleted=bool(deleted&latest),negation_deleted=bool(deleted&protected),
        outside_deleted=bool((deleted-allowed)&lex),attempted=bool(deleted))
