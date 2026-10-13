"""Apply returned reviews plus explicit adjudications to a new, inactive dataset.

Never edit source artifacts. Integer node keys denote pre-import token IDs; inserted
nodes have string keys until the final numbering pass. Ambiguous trees stay out of
the full-tree candidate split files. No model or production code is invoked.
"""
import argparse
import copy
import csv
import difflib
import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCES = {
    'en': 'artifacts/hesitation-tree-reviewed-v2/records.json',
    'fr': 'artifacts/hesitation-fr-es-independent-review-v1/fr/records.json',
    'es': 'artifacts/hesitation-fr-es-independent-review-v1/es/records.json',
    'ca': 'artifacts/hesitation-ca-independent-review-v1/records.json',
}
REVIEWS = ['artifacts/english-review-handoff-v1-agent-review/review-rows.jsonl',
           'artifacts/multilingual-review-handoff-v1-agent-review/review-rows.jsonl']
FOLLOWUP = 'REVIEWER_FOLLOWUP_EN_FR_ES_CA.md'
RELATIONS = set('acl advcl advmod amod appos aux case cc ccomp clf compound conj cop csubj dep det discourse dislocated expl fixed flat goeswith iobj list mark nmod nsubj nummod obj obl orphan parataxis punct reparandum root vocative xcomp'.split())
POLICY_FAMILIES = {'controlled-marked-exposed','negative-control-exposed','adnominal-decision','fronted-purpose'}
ATOM = re.compile(r'\w+|[^\w\s]', re.UNICODE)

def read(path):
    return json.loads(Path(path).read_text())

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def canonical(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()

def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n')

def role_ids(source, name):
    aliases = {'abandoned': ['abandoned_span','earlier_span'], 'latest': ['latest_span','replacement_span'], 'cue': ['cue_span']}
    key = name+'_token_ids'
    if key in source:
        return set(source[key])
    if name == 'cue' and 'cue_spans' in source:
        return {i for s in source['cue_spans'] for i in s['token_ids']}
    for field in aliases[name]:
        if source.get(field):
            return set(source[field]['token_ids'])
    return set()

def policy(source, review, lang):
    sid = source.get('source_id', source['id'])
    family = source['family_id']
    kind = 'full_tree'
    intent, syntax = 'clear', 'settled_agent_proposal'
    reasons = []
    if review['decision'] == 'unsupported':
        kind = 'diagnostic_only'; reasons.append('Unsupported transfer, per returned review.')
    is_policy = family in POLICY_FAMILIES and bool(re.search(r'-(01|03)-repair-unpunctuated$',sid))
    if is_policy and (lang != 'en' or '-03-repair-unpunctuated' in sid):
        kind = 'exclude_pending_review'
        intent = 'likely_repair_unconfirmed' if lang != 'en' and '-03-' in sid else 'ambiguous'
        syntax = 'interpretation_unresolved'
        reasons.append('Follow-up sections 1–2: abstain from deletion; neither alternative is gold.')
    if (lang in ('es','ca') and family == 'clausal-subject') or (lang == 'ca' and family == 'pseudocleft-infinitival-predicate'):
        kind = 'diagnostic_only'; syntax = 'unresolved'
        reasons.append('Follow-up section 4: disputed clitic edge or pseudocleft analysis.')
    if lang == 'ca' and sid == 'safety-v2-nonstandard-existential':
        kind = 'diagnostic_only'; syntax = 'provisional_excluded'
        reasons.append('Original Hi ha retained as unsupported transfer; Hi han is a separate excluded proposal.')
    return dict(supervision_recommendation=kind, intent_status=intent, syntax_status=syntax,
                eligibility_reasons=reasons, policy_row=is_policy)

def initial_nodes(source):
    roles = {name: role_ids(source, name) for name in ('abandoned','latest','cue')}
    upos = source.get('upos', [None]*len(source['words']))
    nodes = []
    units = []
    for i, word in enumerate(source['words'], 1):
        a,b = source['token_starts'][i-1],source['token_ends'][i-1]
        nodes.append(dict(key=i, word=word, head=source['heads'][i-1], rel=source['labels'][i-1],
                          pos=upos[i-1], pos_origin='source_agent_annotation' if upos[i-1] else 'missing',
                          roles=[name for name,ids in roles.items() if i in ids]))
        if units and units[-1]['old_range'] == [a,b]:
            units[-1]['keys'].append(i)
        else:
            units.append(dict(old_range=[a,b],surface=source['text'][a:b],keys=[i]))
    return nodes,units

def structural_changes(source,review,lang,nodes,units,ledger):
    sid=source.get('source_id',source['id'])
    by={n['key']:n for n in nodes}
    serial=0
    def insert(anchor,word,head,rel,pos,roles=None,after=False):
        nonlocal serial
        serial+=1; key=f'insert-{serial}'
        node=dict(key=key,word=word,head=head,rel=rel,pos=pos,pos_origin='imported_reviewer_proposal',roles=list(roles if roles is not None else by[anchor]['roles']))
        idx=next(i for i,n in enumerate(nodes) if n['key']==anchor)+(1 if after else 0)
        nodes.insert(idx,node);by[key]=node
        ui=next(i for i,u in enumerate(units) if anchor in u['keys'])+(1 if after else 0)
        units.insert(ui,dict(old_range=None,surface=word,keys=[key]))
        return key
    def split(key,forms,head):
        nonlocal serial
        unit=next(u for u in units if key in u['keys'])
        assert unit['keys']==[key], ('cannot split existing MWT',sid,key)
        by[key].update(word=forms[0],head=head,rel='case',pos='ADP',pos_origin='imported_reviewer_proposal')
        serial+=1;new=f'insert-{serial}'
        node=dict(key=new,word=forms[1],head=head,rel='det',pos='DET',pos_origin='imported_reviewer_proposal',roles=by[key]['roles'].copy())
        nodes.insert(nodes.index(by[key])+1,node);by[new]=node;unit['keys'].append(new)
        unit['surface']='al'
        ledger.append(dict(action='split_contraction',old_id=key,new_keys=[key,new],forms=forms))
    if lang=='fr' and 'controlled-marked-exposed-04-' in sid:
        for n in list(nodes):
            if n['word'] in ('remplacer','nettoyer'):
                insert(n['key'],'de',n['key'],'mark','ADP')
    if lang=='es' and sid=='htd1-clause_restart-bare-clause-exposed-01-keep':
        anchor=next(n['key'] for n in nodes if n['word']=='pero')
        head=next(n['key'] for n in nodes if n['word']=='lamentaron')
        insert(anchor,',',head,'punct','PUNCT',[])
    if lang=='ca' and sid=='htd1-adjective-sensory-predicate-exposed-01-repair':
        anchor=next(n['key'] for n in nodes if n['word']=='per')
        insert(anchor,'a',anchor,'fixed','ADP',after=True)
    if lang=='ca' and sid=='safety-v2-nonstandard-selected-preposition':
        by[1]['word']='discutir';units[0]['surface']='discutir'
        insert(1,'Vam',1,'aux','AUX',[])
    for patch in review['token_head_relation_changes']:
        key=patch['id']
        if patch['to']=='removed':
            assert key in by
            assert not any(n['head']==key for n in nodes),('removed head has children',sid,key)
            nodes.remove(by.pop(key));units[:]=[u for u in units if key not in u['keys']]
            ledger.append(dict(action='remove_authoring_word',patch=patch))
        if lang=='ca' and ('MWT' in patch['to'] or 'split MWT' in patch['to']):
            if by[key]['word']=='al':
                head=key+1
                assert by[head]['word'] in ('costat','voltant'),(sid,key)
            elif by[key]['word']=='amb':
                head=by[key]['head']
            else: raise ValueError(('unexpected split',sid,patch))
            split(key,['a','el'],head)
    return by

def apply_patches(source,review,lang,nodes,units,ledger,pol):
    by={n['key']:n for n in nodes}
    sid=source.get('source_id',source['id'])
    cue_count=len(role_ids(source,'cue'))
    family=source['family_id']
    for patch in review['token_head_relation_changes']:
        key=patch['id']; to=patch['to']; why=patch['why']
        reason=None
        if pol['policy_row'] and not (lang=='ca' and why.startswith('policy alignment:')):
            reason='Withdrawn interpretation-dependent KEEP patch, follow-up section 1.'
        if family=='clausal-subject' and lang in ('es','ca') and key in by and by[key]['word'] in ('me','em'):
            reason='Unresolved clitic case; preserve source placeholder in diagnostic-only record.'
        if lang=='ca' and family=='pseudocleft-infinitival-predicate':
            # Punctuation and lexical POS fixes remain applicable, structural copula choice does not.
            if 'cop' in why.lower() and 'punct' not in to: reason='Pseudocleft structural policy unresolved.'
        if 'H8' in why and lang=='fr' and cue_count==1:
            reason='French single-word cue: retain source commas on latest head.'
        if lang=='ca' and sid=='safety-v2-nonstandard-existential':
            reason='Replacement diagnostic saved separately; original wording retained.'
        if reason:
            ledger.append(dict(action='withheld',reason=reason,patch=patch));continue
        if to=='removed' or patch['from']=='absent' or 'MWT' in to or to.startswith('split ') or to.startswith('Vam '):
            ledger.append(dict(action='structural_patch_handled',patch=patch));continue
        if lang=='ca' and sid=='htd1-adjective-sensory-predicate-exposed-01-repair' and patch['word']=='per':
            ledger.append(dict(action='structural_patch_handled',patch=patch));continue
        assert key in by,(sid,'missing patch node',patch)
        assert source['words'][key-1]==patch['word'],(sid,'patch word mismatch',patch,source['words'][key-1])
        old_head=re.match(r'^(\d+)\s+',patch['from'])
        if old_head:assert source['heads'][key-1]==int(old_head[1]),(sid,'stale source head',patch)
        match=re.match(r'^(\d+)\s+',to)
        rels=[x for x in re.findall(r'\b[a-z]+(?::[a-z]+)?\b',to.split('(')[0]) if x.split(':')[0] in RELATIONS]
        assert match and len(rels)==1,(sid,'unparsed patch',patch,rels)
        head=int(match.group(1)); rel=rels[0].split(':')[0]
        assert head==0 or head in by,(sid,'invalid old head',patch)
        by[key].update(head=head,rel=rel)
        ledger.append(dict(action='applied',patch=patch))
    for patch in review.get('pos_corrections',[]):
        key=patch['id']
        if key not in by: continue
        if pol['policy_row'] and key in role_ids(source,'cue') and patch['word'].lower() in ('no','non'):
            ledger.append(dict(action='withheld_pos',reason='Withdrawn negator KEEP interpretation',patch=patch));continue
        assert source['words'][key-1]==patch['word'],(sid,'POS word mismatch',patch)
        by[key].update(pos=patch['to'],pos_origin='imported_reviewer_token_correction')
        ledger.append(dict(action='applied_pos',patch=patch))
    if lang=='ca':
        # Final adjudication overrides earlier descriptions on pre-split IDs.
        for i,n in enumerate(nodes[:-1]):
            if n['word']=='més' and nodes[i+1]['word']=='aviat':
                nxt=nodes[i+1]
                adjective=nxt['head'] if n['head']==nxt['key'] else n['head']
                n.update(head=adjective,rel='advmod');nxt.update(head=n['key'],rel='fixed')
                ledger.append(dict(action='adjudicated_mes_aviat',old_keys=[n['key'],nxt['key']]))
        if sid=='safety-v2-nonstandard-existential':
            hi=next(n for n in nodes if n['word']=='Hi');ha=next(n for n in nodes if n['word']=='ha')
            hi.update(head=ha['key'],rel='obl');ledger.append(dict(action='adjudicated_hi',old_key=hi['key'],evidence_status='reviewer_claim_not_locally_verified; diagnostic_only'))
        cue=role_ids(source,'cue')
        if cue and source['label']=='repair':
            cueheads=[n['key'] for n in nodes if n['key'] in cue and n['head'] not in cue]
            assert len(cueheads)==1,(sid,'cue head',cueheads)
            left,right=min(cue),max(cue)
            for n in nodes:
                if isinstance(n['key'],int) and n['word']==',' and n['key'] in (left-1,right+1):
                    n['head']=cueheads[0];n['rel']='punct'
                    ledger.append(dict(action='final_ca_cue_comma',old_id=n['key'],head=cueheads[0]))

def align_text(nodes,units,text,sid):
    """Map existing surface groups to reviewed text; reject unexplained segmentation.

    After explicit token insertions/removals, lexical/punctuation atoms must have
    equal cardinality. SequenceMatcher supplies an auditable edit map, while group
    boundaries preserve source MWTs and literal elisions.
    """
    old_atoms=[]; group_indices=[]
    for unit in units:
        atoms=ATOM.findall(unit['surface'])
        group_indices.append(list(range(len(old_atoms),len(old_atoms)+len(atoms))))
        old_atoms.extend(atoms)
    matches=list(ATOM.finditer(text));new_atoms=[m.group() for m in matches]
    assert len(old_atoms)==len(new_atoms),(sid,'atom count',len(old_atoms),len(new_atoms),old_atoms,new_atoms)
    # Explicit structural operations have already fixed insertion/removal; remaining
    # changes are aligned in order, including inflection and capitalization.
    by={n['key']:n for n in nodes}
    for unit,indices in zip(units,group_indices):
        a,b=matches[indices[0]].start(),matches[indices[-1]].end()
        unit.update(start=a,end=b,surface=text[a:b])
        if len(unit['keys'])==1:
            by[unit['keys'][0]]['word']=unit['surface']
        for key in unit['keys']:by[key].update(start=a,end=b)
    return [dict(old=old_atoms[a:b],new=new_atoms[c:d]) for op,a,b,c,d in difflib.SequenceMatcher(a=old_atoms,b=new_atoms,autojunk=False).get_opcodes() if op!='equal']

def build_record(source,review,lang):
    source=copy.deepcopy(source)
    sid=source.get('source_id',source['id'])
    pol=policy(source,review,lang)
    nodes,units=initial_nodes(source);ledger=[]
    structural_changes(source,review,lang,nodes,units,ledger)
    apply_patches(source,review,lang,nodes,units,ledger,pol)
    text=review['corrected_input'] or source['text']
    target=review['corrected_target'] or source['intended_output']
    if pol['policy_row']:
        # Original repair analysis is retained as an alternative, never relabeled
        # KEEP based solely on a conservative runtime decision.
        target=source['intended_output']
    if lang=='ca' and sid=='safety-v2-nonstandard-existential':
        text=source['text'];target=source['intended_output']
    atom_edits=align_text(nodes,units,text,sid)
    keys={n['key']:i for i,n in enumerate(nodes,1)};keys[0]=0
    mapping={str(i):[keys[n['key']] for n in nodes if n['key']==i] for i in source['token_ids']}
    for u in units:
        originals=[k for k in u['keys'] if isinstance(k,int)]
        if len(originals)==1 and len(u['keys'])>1:
            mapping[str(originals[0])]=[keys[k] for k in u['keys']]
    r=dict(schema_version='hesitation-multilingual-adjudicated-v1',id=source['id'],source_id=sid,language=lang,
           family_id=source['family_id'],source_family_id=source.get('source_family_id',source['family_id']),
           pair_id=source.get('pair_id',source.get('source_pair_id')),assigned_split=source['assigned_split'],
           label=source['label'],source_intent=source['label'],text=text,intended_output=target,
           words=[n['word'] for n in nodes],token_ids=list(range(1,len(nodes)+1)),
           heads=[keys[n['head']] for n in nodes],labels=[n['rel'] for n in nodes],
           token_starts=[n['start'] for n in nodes],token_ends=[n['end'] for n in nodes],
           pos_candidates=[n['pos'] for n in nodes],pos_annotation_origin=[n['pos_origin'] for n in nodes],
           pos_supervision_complete=False,morphology_supervision_complete=False,lemma_supervision_complete=False,
           human_reviewed=False,linguistic_correctness_verified=False,training_ready=False,
           active_training=False,independent_test_eligible=False,**{k:v for k,v in pol.items() if k!='policy_row'})
    r['syntax_training_eligible']=r['supervision_recommendation']=='full_tree'
    r['surface_ud_map']=[dict(surface=u['surface'],start=u['start'],end=u['end'],ud_token_ids=[keys[k] for k in u['keys']],ud_forms=[r['words'][keys[k]-1] for k in u['keys']]) for u in units]
    r['mwt']=[dict(form=u['surface'],start=u['start'],end=u['end'],token_ids=u['ud_token_ids'],words=u['ud_forms']) for u in r['surface_ud_map'] if len(u['ud_token_ids'])>1]
    for name in ('abandoned','latest','cue'):
        ids=[keys[n['key']] for n in nodes if name in n['roles']]
        r[name+'_token_ids']=ids
        r[name+'_span']=span(r,ids)
    r['cue_spans']=[r['cue_span']] if r['cue_span'] else []
    r['replacement_span']=r['latest_span']
    repair=[i for i,l in enumerate(r['labels'],1) if l=='reparandum']
    r['repair_edge']=dict(dep=repair[0],head=r['heads'][repair[0]-1],label='reparandum') if repair else None
    r['delete_spans']=[]
    if source['label']=='repair':
        a=r['abandoned_span']['start'];b=r['latest_span']['start']
        r['delete_spans']=[dict(start=a,end=b,text=text[a:b])]
    r['delete_token_ids']=[i for i,(a,b) in enumerate(zip(r['token_starts'],r['token_ends']),1) if any(d['start']<=a and b<=d['end'] for d in r['delete_spans'])]
    r['runtime_policy']='preserve_input_due_to_ambiguity' if r['intent_status']!='clear' else 'not_deployed'
    r['alternative_keep_target']=text if r['intent_status']!='clear' else None
    r['review_provenance']=dict(source_path=SOURCES[lang],source_record_sha256=canonical(source),review_row=review,adjudication_document=FOLLOWUP,old_to_new_token_ids=mapping,new_to_old_token_ids={str(keys[n['key']]):n['key'] if isinstance(n['key'],int) else None for n in nodes},applied_and_withheld_patches=ledger,text_atom_changes=atom_edits)
    r['current_review_decision']='unsupported' if lang=='ca' and sid=='safety-v2-nonstandard-existential' else review['decision']
    r['attachment_scope_notes']=[review['remaining_uncertainty']] if re.search(r'attach|scope',review.get('remaining_uncertainty',''),re.I) else []
    if r['attachment_scope_notes'] and r['syntax_status']=='settled_agent_proposal':r['syntax_status']='canonical_proposal_with_attachment_notes'
    return r

def span(r,ids):
    if not ids:return None
    a=min(r['token_starts'][i-1] for i in ids);b=max(r['token_ends'][i-1] for i in ids)
    return dict(start=a,end=b,text=r['text'][a:b],token_ids=ids)

def validate(r):
    sid=(r['language'],r['source_id'])
    def need(x,msg):
        if not x:raise AssertionError((sid,msg))
    n=len(r['words']);need(r['token_ids']==list(range(1,n+1)),'token IDs')
    need(all(len(r[k])==n for k in ['heads','labels','token_starts','token_ends','pos_candidates']),'array lengths')
    need(r['heads'].count(0)==1,'one root')
    for i,(h,l) in enumerate(zip(r['heads'],r['labels']),1):
        need(type(h)is int and 0<=h<=n and h!=i,'head bounds/self-edge')
        need(l in RELATIONS and ((h==0)==(l=='root')),'root/label consistency')
        seen={i};p=h
        while p:
            need(p not in seen,f'cycle at {i}');seen.add(p);p=r['heads'][p-1]
    covered=set();end=0
    for unit in r['surface_ud_map']:
        a,b=unit['start'],unit['end'];ids=unit['ud_token_ids']
        need(a>=end and not r['text'][end:a].strip(),'uncovered/overlapping characters')
        need(r['text'][a:b]==unit['surface'],'surface spelling')
        need(not covered.intersection(ids),'duplicate word mapping');covered.update(ids)
        need(ids==list(range(min(ids),max(ids)+1)),'noncontiguous surface group')
        for i in ids:need(r['token_starts'][i-1]==a and r['token_ends'][i-1]==b,'word offsets')
        if len(ids)==1:need(r['words'][ids[0]-1]==unit['surface'],'literal singleton')
        end=b
    need(covered==set(range(1,n+1)) and not r['text'][end:].strip(),'full surface coverage')
    deleted=set(r['delete_token_ids']);latest=set(r['latest_token_ids']);old=set(r['abandoned_token_ids']);cue=set(r['cue_token_ids'])
    rebuilt=r['text']
    for d in reversed(r['delete_spans']):
        need(r['text'][d['start']:d['end']]==d['text'],'deletion substring')
        for a,b in zip(r['token_starts'],r['token_ends']):
            if max(a,d['start'])<min(b,d['end']):need(d['start']<=a and b<=d['end'],'partial token/MWT deletion')
        rebuilt=rebuilt[:d['start']]+rebuilt[d['end']:]
    # Adjacent elision pieces form one lexical surface unit. A deletion boundary
    # may not bisect l'avís or d'aigua even though the UD words have literal slices.
    lexical=[]
    for u in r['surface_ud_map']:
        punct=all(r['labels'][i-1]=='punct' for i in u['ud_token_ids'])
        if lexical and lexical[-1]['end']==u['start'] and not punct and not lexical[-1]['punct']:
            lexical[-1]['end']=u['end']
        else:lexical.append(dict(start=u['start'],end=u['end'],punct=punct))
    for u in lexical:
        for d in r['delete_spans']:
            if max(u['start'],d['start'])<min(u['end'],d['end']):need(d['start']<=u['start'] and u['end']<=d['end'],'partial lexical-unit deletion')
    need(rebuilt==r['intended_output'],f"exact target mismatch: {rebuilt!r} != {r['intended_output']!r}")
    if r['label']=='keep':need(not deleted and r['repair_edge'] is None and 'reparandum' not in r['labels'],'KEEP untouched')
    else:
        e=r['repair_edge'];need(bool(e) and e['dep']<e['head'] and e['dep'] in old and e['head'] in latest,'earlier->latest')
        need(r['labels'].count('reparandum')==1,'single repair edge')
        descendants={e['dep']}
        while True:
            enlarged=descendants|{i for i,h in enumerate(r['heads'],1) if h in descendants}
            if enlarged==descendants:break
            descendants=enlarged
        need({i for i in descendants if r['labels'][i-1]!='punct'}==old,'exact abandoned lexical subtree')
        need(old|cue<=deleted and not deleted&latest,'latest and role protection')
        need(all(i in old|cue or r['labels'][i-1]=='punct' for i in deleted),'unrelated lexical deletion')
        need(all(h not in deleted for i,h in enumerate(r['heads'],1) if i not in deleted),'kept word depends on deleted word')
    need(not r['human_reviewed'] and not r['training_ready'] and not r['active_training'],'provenance/readiness')
    need(r['syntax_training_eligible']==(r['supervision_recommendation']=='full_tree'),'supervision gate')
    return True

def validate_dataset(rows, sources):
    assert len(rows)==1412 and len({(r['language'],r['source_id']) for r in rows})==1412
    expected={lang:{r.get('source_id',r['id']):r for r in data} for lang,data in sources.items()}
    families=defaultdict(set);surface_splits=defaultdict(set)
    for r in rows:
        validate(r)
        old=expected[r['language']][r['source_id']]
        assert r['assigned_split']==old['assigned_split'] and r['family_id']==old['family_id'] and r['label']==old['label']
        assert r['pair_id']==old.get('pair_id',old.get('source_pair_id'))
        families[r['family_id']].add(r['assigned_split'])
        for field in ('text','intended_output'):
            normalized=' '.join(re.findall(r'\w+',r[field].casefold()))
            surface_splits[r['language'],field,normalized].add(r['assigned_split'])
    assert len(families)==55 and all(len(s)==1 for s in families.values())
    assert all(len(s)==1 for s in surface_splits.values()),'normalized cross-split duplicate'

def conllu(rows):
    lines=[]
    for r in rows:
        lines += [f"# sent_id = {r['language']}:{r['source_id']}",f"# text = {r['text']}",f"# supervision = {r['supervision_recommendation']}",'# annotation_status = AI-reviewed proposal; POS/morphology not supervised']
        mwts={m['token_ids'][0]:m for m in r['mwt']}
        for i,w,h,l in zip(r['token_ids'],r['words'],r['heads'],r['labels']):
            if i in mwts:
                m=mwts[i];lines.append('\t'.join([f"{min(m['token_ids'])}-{max(m['token_ids'])}",m['form'],'_','_','_','_','_','_','_','_']))
            misc=f"StartChar={r['token_starts'][i-1]}|EndChar={r['token_ends'][i-1]}"
            lines.append('\t'.join([str(i),w,'_','_','_','_',str(h),l,'_',misc]))
        lines.append('')
    return '\n'.join(lines)+'\n'

def review_packet(rows):
    lines=['# Adjudicated multilingual hesitation proposals','',
           'New version after returned review and written adjudication. Full-tree candidates are agent-reviewed proposals, not human gold. Inactive; no model training. Original labels remain lineage; ambiguous records include an unchanged runtime alternative. POS candidates are incomplete and not POS training labels.','']
    for r in rows:
        lines += [f"## {r['language']} / {r['source_id']}",'',f"{r['assigned_split']} · {r['label']} · **{r['supervision_recommendation']}**",'',f"Input: {r['text']}",'',f"Proposed target: {r['intended_output']}",'',f"Intent: {r['intent_status']} · Syntax: {r['syntax_status']}",'',f"Deletion: {json.dumps(r['delete_spans'],ensure_ascii=False)}",'',f"Latest: {json.dumps(r['latest_span'],ensure_ascii=False)}",'',f"Old → new IDs: {json.dumps(r['review_provenance']['old_to_new_token_ids'],ensure_ascii=False)}",'']
        if r['alternative_keep_target']:lines += [f"Runtime abstention target: {r['alternative_keep_target']}",'']
        lines += ['|ID|Word|Head|Relation|POS candidate (not supervised)|','|---|---|---|---|---|']
        for i,w,h,l,p in zip(r['token_ids'],r['words'],r['heads'],r['labels'],r['pos_candidates']):
            lines.append('|'+ '|'.join(str(x or '_').replace('|','\\|') if j!=2 else str(x) for j,x in enumerate([i,w,h,l,p]))+'|')
        lines += ['',f"Remaining source-review note: {r['review_provenance']['review_row'].get('remaining_uncertainty','')}",'','Next reviewer notes:','']
    return '\n'.join(lines)+'\n'

def load_inputs():
    reviews={}
    for path in REVIEWS:
        for line in (ROOT/path).read_text().splitlines():
            r=json.loads(line);key=(r['language'],r['source_id']);assert key not in reviews;reviews[key]=r
    sources={lang:read(ROOT/path) for lang,path in SOURCES.items()}
    return sources,reviews

def construct():
    sources,reviews=load_inputs();out=[];failures=[]
    for lang,rows in sources.items():
        for source in rows:
            sid=source.get('source_id',source['id'])
            try:
                r=build_record(source,reviews[lang,sid],lang);validate(r);out.append(r)
            except Exception as error:
                failures.append(dict(language=lang,source_id=sid,error=str(error)))
    return out,failures

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');parser.add_argument('--output',default='artifacts/hesitation-multilingual-adjudicated-v1');args=parser.parse_args()
    protected=set(SOURCES.values())|set(REVIEWS)|{FOLLOWUP}
    for relative in list(SOURCES.values())+REVIEWS:
        for p in (ROOT/relative).parent.rglob('*'):
            if p.is_file() and p.suffix in ('.json','.jsonl','.csv','.md','.conllu'):
                protected.add(str(p.relative_to(ROOT)))
    protected=sorted(protected)
    hashes={p:sha(ROOT/p) for p in protected}
    rows,failures=construct()
    if failures:
        print(json.dumps(dict(successful=len(rows),failures=failures),ensure_ascii=False,indent=2));raise SystemExit(1)
    sources,_=load_inputs();validate_dataset(rows,sources)
    assert hashes=={p:sha(ROOT/p) for p in protected}
    summary={lang:dict(records=len(a),dispositions=dict(Counter(r['supervision_recommendation'] for r in a)),source_intents=dict(Counter(r['label'] for r in a)),splits=dict(Counter(r['assigned_split'] for r in a)),candidate_splits={s:dict(Counter(r['label'] for r in a if r['assigned_split']==s and r['syntax_training_eligible'])) for s in ('train','dev','test')},changed_text=sum(r['text']!=sources[lang][j]['text'] for j,r in enumerate(a))) for lang in SOURCES for a in [[r for r in rows if r['language']==lang]]}
    if args.check:
        print(json.dumps(summary,indent=2));return
    dest=ROOT/args.output
    if dest.exists():raise SystemExit('Refusing to overwrite existing dataset version')
    dest.mkdir(parents=True)
    write(dest/'records.json',rows)
    for lang in SOURCES:
        a=[r for r in rows if r['language']==lang]
        write(dest/lang/'records.json',a)
        for split in ('train','dev','test'):
            write(dest/lang/f'{split}.json',[r for r in a if r['assigned_split']==split])
            write(dest/'syntax-candidates'/lang/f'{split}.json',[r for r in a if r['assigned_split']==split and r['syntax_training_eligible']])
            (dest/'syntax-candidates'/lang/f'{split}.conllu').write_text(conllu([r for r in a if r['assigned_split']==split and r['syntax_training_eligible']]))
        (dest/lang/'REVIEW.md').write_text(review_packet(a))
    write(dest/'diagnostic-only.json',[r for r in rows if r['supervision_recommendation']=='diagnostic_only'])
    write(dest/'excluded-pending-review.json',[r for r in rows if r['supervision_recommendation']=='exclude_pending_review'])
    # Separate new diagnostic: never replaces the original source ID or enters training.
    variant=copy.deepcopy(next(r for r in rows if r['language']=='ca' and r['source_id']=='safety-v2-nonstandard-existential'))
    variant.update(id=variant['id']+'-hi-han-proposal-v1',source_id=variant['source_id']+'-hi-han-proposal-v1',variant_parent_id=variant['id'],supervision_recommendation='exclude_pending_review',syntax_training_eligible=False,syntax_status='replacement_diagnostic_pending_review')
    i=variant['words'].index('ha');end=variant['token_ends'][i];variant['words'][i]='han';variant['text']=variant['text'][:end]+'n'+variant['text'][end:];variant['intended_output']=variant['text']
    for j in range(len(variant['words'])):
        if variant['token_starts'][j]>=end:variant['token_starts'][j]+=1
        if variant['token_ends'][j]>=end:variant['token_ends'][j]+=1
    for u in variant['surface_ud_map']:
        if u['start']>=end:u['start']+=1
        if u['end']>=end:u['end']+=1
        u['surface']=variant['text'][u['start']:u['end']];u['ud_forms']=[variant['words'][k-1] for k in u['ud_token_ids']]
    variant['eligibility_reasons']=['Follow-up section 5: replacement diagnostic, not original transfer; excluded.']
    variant['current_review_decision']='replacement_diagnostic_pending_review'
    variant['replacement_diagnostic_change']={'original_text':next(r['text'] for r in rows if r['language']=='ca' and r['source_id']=='safety-v2-nonstandard-existential'),'word_change':'ha -> han','new_id':variant['id'],'excluded':True}
    validate(variant);write(dest/'replacement-diagnostic-proposals.json',[variant])
    write(dest/'summary.json',summary)
    write(dest/'patch-audit.json',[dict(language=r['language'],source_id=r['source_id'],supervision=r['supervision_recommendation'],patches=r['review_provenance']['applied_and_withheld_patches'],text_atom_changes=r['review_provenance']['text_atom_changes']) for r in rows])
    write(dest/'validation.json',dict(records=1412,replacement_proposals=1,structural_and_deletion_checks='passed',source_hashes_preserved=True,training_run=False))
    test_path=ROOT/'tests/test_import_reviewed_multilingual_v1.py'
    write(dest/'verification-tests.json',dict(command='.venv/bin/python -m pytest -q tests/test_import_reviewed_multilingual_v1.py',test_source_sha256=sha(test_path),note='Run this command independently; this file does not claim execution.'))
    for path in protected:
        target=dest/'provenance'/path;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/path).read_bytes())
    header=['# Multilingual hesitation dataset after review adjudication','',
            'All 1,412 original records are preserved, with corrections applied in this new version. Original source IDs, pairs, families, KEEP/REPAIR intent and train/dev/test assignments remain unchanged. An additional Catalan Hi han replacement diagnostic is stored separately and excluded. Nothing has been trained or enabled in production.','',
            '|Language|Full-tree candidates|Diagnostic only|Excluded pending review|','|---|---:|---:|---:|']
    for lang,v in summary.items():
        c=v['dispositions'];header.append(f"|{lang}|{c.get('full_tree',0)}|{c.get('diagnostic_only',0)}|{c.get('exclude_pending_review',0)}|")
    header += ['',
      '## Applied adjudications','',
      '- Restore four English unpunctuated bare-no repair trees. Four English I-mean cases and eight cases per other language remain outside full-tree candidates; retain repair analyses only as proposals and expose unchanged runtime alternatives.',
      '- French single-word cue commas remain on the latest head; multi-word cue commas follow the reviewed cue-head convention. English source conventions are retained; Spanish/Catalan cue commas use the cue head, including after Catalan token splits.',
      '- Apply all agreed patches, including patches attached to accept decisions. Correct French final punctuation and locution POS, Spanish relations and locutions, and Catalan clitics, modal markers and contractions. Normalize all twelve degree més aviat constructions as adjudicated.',
      '- Keep the twenty ES/CA clausal-subject rows and ten Catalan pseudocleft rows diagnostic-only. Preserve unsupported-transfer examples outside full-tree candidates.',
      '- Preserve intentional article/agreement errors and the SWS fragments. Corrected authoring text changes are tracked separately from runtime deletion.',
      '- Rebuild all token numbering, surface/MWT maps, offsets and role spans. Each record contains its old-to-new mapping, full returned review, and applied/withheld patch ledger.',
      '', '## Files and use','',
      '`records.json` contains all original records. Language directories contain full partition copies and editable REVIEW.md files. `syntax-candidates/<language>/{train,dev,test}.json` and `.conllu` contain only full-tree candidates, preserving their original splits. These files are prepared for a future authorized training run; no active loader/configuration points to them.',
      '',
      '`diagnostic-only.json`, `excluded-pending-review.json`, and `replacement-diagnostic-proposals.json` are deliberately separate. For ambiguous records, label/heads/target retain a proposed repair analysis for traceability; use `supervision_recommendation` and `syntax_training_eligible`, not the original label, to select supervision. Runtime abstention is not a gold KEEP tree.',
      '',
      '`patch-audit.json` records every consumed/withheld patch. `provenance/` preserves inputs and the reviewer’s written responses; `manifest.json` hashes inputs, importer and outputs. `validation.json` reports structural and deletion validation. The focused test command is documented in `verification-tests.json`.',
      '', '## Important limits','',
      'All annotations remain AI-reviewed proposals, not human gold. Canonical attachments with remaining scope alternatives have explicit notes. Some Catalan policy evidence is reviewer-reported rather than locally reverified. The excluded Hi han proposal does not certify a normative language judgment.',
      '',
      'POS corrections are token-level proposals only; no language is advertised here as complete POS/morphology/lemma training supervision. CoNLL-U exports intentionally leave those columns blank. This is a syntax/hesitation dataset, not NER data.',
      '',
      'Heldout partitions were already inspected and translated variants share lineage. They remain development/regression diagnostics, not fresh generalization tests. Structural validation does not establish linguistic correctness. No model inference or retraining was performed.','']
    (dest/'README.md').write_text('\n'.join(header))
    assert hashes=={p:sha(ROOT/p) for p in protected}
    write(dest/'manifest.json',dict(source_sha256=hashes,importer_sha256=sha(__file__),output_sha256={str(p.relative_to(dest)):sha(p) for p in sorted(dest.rglob('*')) if p.is_file()},human_gold=False,production_modified=False))
    print(json.dumps(dict(output=str(dest),summary=summary),indent=2))

if __name__=='__main__':main()
