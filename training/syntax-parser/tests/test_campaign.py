import copy
import json
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import pytest
import torch
from campaign.common import *
from campaign.surface import aligned_units,input_only,view
from campaign.repair import repair,score
from campaign.dataset import make_orders,parse_feats,inventories
from campaign.network import grammar_targets,masked_ce
from campaign.ner import normalize_row,decode,counts,load_corpus
from campaign.metrics import select_feature,paired_effect


def example(text,words,heads,labels,lang='en'):
    """Build a minimal aligned tree fixture without hidden evaluation metadata."""
    return dict(text=text,words=words,heads=heads,labels=labels,language=lang)


def test_repair_without_gold_preserves_latest():
    """Verify deletion depends on predicted trees rather than injected gold repair hints."""
    r=example('the cat the dog runs',['the','cat','the','dog','runs'],[2,4,4,5,0],['det','reparandum','det','nsubj','root'])
    public=input_only(r)
    out=repair(public,r['heads'],r['labels'])
    assert out['text']=='the dog runs' and out['deleted_token_ids']==[1,2]
    assert set(public)=={'text','words','language','surface_ud_map'}
    r.update(abandoned_token_ids=[5],latest_token_ids=[2],label='keep',intended_output='wrong',delete_token_ids=[5])
    assert repair(input_only(r),r['heads'],r['labels'])==out
    assert score(r,out)['harmful_keep'] and score(r,out)['latest_deleted']


def test_keep_negation_parallel_and_invalid_trees():
    """Keep valid parallel complements and protected negation, rejecting cyclic trees."""
    r=example('I want to write to edit',['I','want','to','write','to','edit'],[2,0,4,2,6,2],['nsubj','root','mark','xcomp','mark','xcomp'])
    assert repair(input_only(r),r['heads'],r['labels'])['text']==r['text']
    r=example('not good great',['not','good','great'],[2,3,0],['advmod','reparandum','root'])
    assert repair(input_only(r),r['heads'],r['labels'])['text']==r['text']
    assert repair(input_only(r),[2,1,0],r['labels'])['error']


def test_multilingual_cues_and_surface_units():
    """Allow recognized cues while preserving whole contraction surface units."""
    for lang,cue in [('en','sorry'),('fr','pardon'),('es','perdón')]:
        r=example(f'rouge , {cue} , bleu',['rouge',',',cue,',','bleu'],[5,3,5,3,0],['reparandum','punct','discourse','punct','root'],lang)
        assert repair(input_only(r),r['heads'],r['labels'])['text']=='bleu'
    r=example('au bureau au dépôt',['à','le','bureau','à','le','dépôt'],[3,3,6,6,6,0],['case','det','reparandum','case','det','root'],'fr')
    r['mwt']=[{'id':'1-2','form':'au'},{'id':'4-5','form':'au'}]
    assert repair(input_only(r),r['heads'],r['labels'])['text']=='au dépôt'
    r['heads']=[6,3,6,6,6,0] # earlier subtree has only one part of au
    assert repair(input_only(r),r['heads'],r['labels'])['text']==r['text']


def test_views_preserve_heads_and_reject_unsafe_punctuation():
    """Check augmentation remapping, heldout collisions and nonleaf punctuation rejection."""
    r=example('Dog runs.',['Dog','runs','.'],[2,0,2],['nsubj','root','punct'])
    out=view(r,'punctuation_reduced');assert out['text']=='Dog runs' and out['heads']==[2,0]
    assert view(r,'lowercase')['text']=='dog runs.'
    assert view(r,'lowercase',{'dog runs.'})['text']==r['text']
    r['heads']=[3,0,2]
    assert view(r,'punctuation_reduced')['augmentation']=='original'
    r=example('Dog, no, cat',['Dog',',','no',',','cat'],[5,3,5,3,0],['reparandum','punct','discourse','punct','root'])
    assert view(r,'punctuation_reduced')['text']==r['text']


def test_grammar_missing_not_absent_and_train_only_inventory():
    """Separate unknown supervision from observed absence and support fully masked loss."""
    row=dict(upos=['NOUN'],morph=[{'Number':'Sing'}],morph_observed=[{a:a in ('Number','Gender') for a in ATTRIBUTES}])
    vocab=inventories([row]);t=grammar_targets([row],1,vocab,'cpu')
    assert t['Gender'].item()==0 and t['Number'].item()==1 and t['Mood'].item()==-100
    assert parse_feats('Number=Plur,Sing')['Number']=='Plur,Sing'
    logits=torch.randn(1,1,2,requires_grad=True);loss=masked_ce(logits,torch.tensor([[-100]]));loss.backward()
    assert loss.item()==0 and torch.equal(logits.grad,torch.zeros_like(logits))


def test_campaign_exposure_and_paired_control():
    """Verify fixed update budgets, local cycling and matched ordinary-control slots."""
    rows=[{'language':l,'id':str(i)} for l in LANGUAGES for i in range(3000)]
    local=[{'language':l,'id':str(i)} for l in LANGUAGES for i in range({'en':233,'fr':227,'es':228}[l])]
    a=make_orders(rows,local,42,6);b=make_orders(rows,local,42,6)
    assert a==b and len(a['mix'])==len(a['control'])==627
    assert sum(len(s['indices']) for s in a['mix'] if s['source']=='local')==1008
    for x,y in zip(a['mix'],a['control']):
        assert x['language']==y['language'] and x['view']==y['view'] and len(x['indices'])==len(y['indices'])
        if x['source']=='ud':assert x==y
    for l in LANGUAGES:
        picked=[i for s in a['mix'] if s['source']=='local' and s['language']==l for i in s['indices']]
        expected={i for i,r in enumerate(local) if r['language']==l}
        assert set(picked)==expected and len(set(picked[:len(expected)]))==len(expected)
    assert len(make_orders(rows,local,42,1)['base'])==564


def test_ner_unknown_regions_and_span_boundaries():
    """Mask unknown NER regions and reject entity boundaries that cut tokens."""
    row=dict(text='Ana uses X.',spans=[dict(start=0,end=3,type='person')],annotation_complete=False,unknown_spans=[dict(start=9,end=10)])
    r=normalize_row(row);assert r['ner_targets']==[1,0,-100,0]
    spans=decode(r,['B-person','O','B-project','O'])
    c=counts(r,spans);assert c['tp']==1 and c['fp']==0
    bad=copy.deepcopy(row);bad['spans'][0]['end']=2
    with pytest.raises(ValueError):normalize_row(bad)


def test_feature_selection_pairs_and_uncertainty():
    """Require paired practical gains and positive uncertainty bounds for feature selection."""
    p=dict(macro_pp=.4,per_language_pp=dict(en=.5,fr=.3,es=.4),macro_ci95_pp=[.1,.7])
    assert select_feature([p,p])['selected']=='feature'
    q=copy.deepcopy(p);q['macro_ci95_pp'][0]=-.1
    assert select_feature([p,q])['selected']=='context'


def test_negation_score_is_independent_of_predicted_protection():
    """Detect negation loss even when a forged model output omits safety metadata."""
    r=example('not red blue',['not','red','blue'],[2,3,0],['advmod','reparandum','root'])
    r.update(label='keep',intended_output=r['text'],latest_token_ids=[3],delete_token_ids=[])
    forged=dict(text='blue',deleted_token_ids=[1,2],edits=[])
    assert score(r,forged)['negation_deleted']


def test_frozen_teacher_probabilities_can_train_fusion():
    """Ensure detached cached teacher outputs still permit fusion-layer gradients."""
    from campaign.network import Teacher
    from types import SimpleNamespace
    teacher=Teacher.__new__(Teacher)
    teacher.digest='test';teacher.vocab={'upos':['NOUN','VERB']};teacher.cache={}
    layer=torch.nn.Linear(384,2).requires_grad_(False)
    teacher.package=SimpleNamespace(online=lambda rows:torch.ones(len(rows),1,384),head=lambda x:{'upos':layer(x)})
    rows=[dict(text='x',words=['x'])]
    probabilities=teacher.probabilities(rows)
    fusion=torch.nn.Linear(2,384)
    fusion(probabilities).sum().backward()
    assert fusion.weight.grad is not None and layer.weight.grad is None
    changed=[dict(text='X',words=['X'],augmentation='lowercase')]
    teacher.probabilities(changed)
    assert len(teacher.cache)==2


def test_ner_split_family_gate(tmp_path):
    """Reject repeated source families across NER training and heldout splits."""
    corpus=[]
    for split in ('train','dev','confirmation'):
        for lang in LANGUAGES:
            corpus.append(dict(id=lang+split,language=lang,split=split,text=lang+' '+split+' Ana',spans=[],annotation_complete=True,reviewed=True,review_provenance='synthetic unit test fixture, not a corpus',group_id=lang+split,source_id=lang+split,template_id=lang+split,name_families=[]))
    path=tmp_path/'ner.json';path.write_text(json.dumps(corpus))
    assert len(load_corpus(path))==9
    corpus[-1]['source_id']=corpus[0]['source_id'];path.write_text(json.dumps(corpus))
    with pytest.raises(ValueError,match='leakage'):load_corpus(path)


def test_ner_lowercase_remaps_unknown_and_multichar_unicode():
    """Keep entity and unknown-region offsets aligned after Unicode case expansion."""
    from campaign.ner_runner import ner_view
    r=normalize_row(dict(text='İ Ana.',spans=[dict(start=2,end=5,type='person')],annotation_complete=False,unknown_spans=[dict(start=0,end=1)]))
    v=ner_view(r,'lowercase')
    assert v['text'][v['spans'][0]['start']:v['spans'][0]['end']]=='ana'
    assert v['unknown_spans'][0]['end']==2
    assert -100 in v['ner_targets']


def test_french_non_negation_is_not_a_cue_without_discourse_role():
    """Protect French non when its syntactic role indicates negation."""
    r=example('non conforme conforme',['non','conforme','conforme'],[2,3,0],['advmod','reparandum','root'],'fr')
    assert repair(input_only(r),r['heads'],r['labels'])['text']==r['text']


def test_partial_checkpoint_resumes_without_redoing_batches(tmp_path):
    """Continue from the saved batch cursor and skip an already completed epoch."""
    from campaign.training import run_epochs,capture,restore,save
    from campaign.network import Package
    from unittest.mock import patch
    from types import SimpleNamespace
    # Lightweight trainable stand-in checks runner control flow, not transformer quality.
    class Toy:
        def __init__(self):
            """Create a tiny trainable stand-in for checkpoint-runner tests."""
            self.task='ner';self.device='cpu';self.vocab={};self.seed=42;self.feature=False;self.teacher=None;self.protocol={};self.base_digest='frozen';self.steps=0
            self.head=torch.nn.Linear(1,1);self.fusion=None
            self.lm=SimpleNamespace(model=None);self.opt=torch.optim.AdamW(self.head.parameters());self.calls=[]
        def update(self,rows):
            """Record processed rows and advance a deterministic test optimizer or counter."""
            self.calls.append(rows[0]['id']);self.opt.zero_grad();loss=self.head(torch.ones(1,1)).sum();loss.backward();self.opt.step();self.steps+=1
            return dict(loss=loss.item())
    rows=[dict(id=str(i),text='x',words=['x']) for i in range(3)]
    schedule=[dict(source='ner',indices=[i],view='original') for i in range(3)]
    with patch('campaign.training.adapter_state',return_value={}),patch('campaign.training.load_adapter_state'),patch('campaign.training.base_hash',return_value='frozen'),patch('campaign.training.evaluate',return_value={}):
        pkg=Toy();first=pkg.update(rows[:1]);saved=capture(pkg,dict(epoch=1,cursor=1,complete=False,smoke=True,bundle_hash='data',backend='cpu',plan_hash=fingerprint(schedule),loss_sum=first['loss'],augmentation_rejections={'earlier':1}))
        out=tmp_path/'run';out.mkdir();save(out/'latest.pt',saved)
        fresh=Toy();run_epochs(fresh,out,{'1':schedule},{'ner':rows},[],set(),[1],'data',smoke=True,max_batches=3)
        assert fresh.calls==['1','2'] and fresh.steps==3
        again=Toy();run_epochs(again,out,{'1':schedule},{'ner':rows},[],set(),[1],'data',smoke=True,max_batches=3)
        assert again.calls==[]


def test_resume_hash_includes_shared_training_dependencies(monkeypatch):
    """Detect changed encoder, parser, adapter, target and runner implementations."""
    import campaign.training as training
    original=training.sha
    baseline=training.implementation_hash()
    for dependency in ('campaign/trees.py','campaign/encoder.py','campaign/adapters.py','campaign/parser.py','campaign/training.py'):
        monkeypatch.setattr(training,'sha',lambda path, target=dependency: 'changed' if str(path)==target else original(path))
        assert training.implementation_hash()!=baseline
    monkeypatch.setattr(training,'sha',original)


def test_endpoint_prerequisites_do_not_consume_holdout(tmp_path,monkeypatch):
    """Check missing or changed prerequisites before reserving the one-use COSER marker."""
    import campaign.cli as cli
    data=tmp_path/'data';data.mkdir();run=tmp_path/'run';run.mkdir()
    protocol={'source_sha256':{'artifacts/data/es_coser-test.jsonl':'source'}}
    monkeypatch.setattr(cli,'bundle',lambda _: (data,protocol,{},'bundle'))
    monkeypatch.setattr(cli,'sha',lambda _: 'source')
    write(run/'run-lock.json',dict(smoke=False,bundle_hash='bundle',implementation_hash=cli.implementation_hash()))
    write(run/'campaign-status.json',{})
    write(run/'syntax-selection.json',{'selected':'feature'})
    write(data/'coser-endpoint-only.json',[])
    with pytest.raises(ValueError,match='Missing endpoint checkpoint'):cli.endpoint(data,run,'cpu')
    assert not (run/'COSER-consumed.json').exists()
    for seed in (42,43):
        for name,epoch in [('S-feature',5),('H-control',7),('H-mix',7),('G',5)]:
            path=run/f'{name}-seed{seed}/epoch{epoch}.pt';path.parent.mkdir();path.touch()
    monkeypatch.setattr(cli,'sha',lambda _: 'changed')
    with pytest.raises(ValueError,match='COSER source changed'):cli.endpoint(data,run,'cpu')
    assert not (run/'COSER-consumed.json').exists()
    monkeypatch.setattr(cli,'sha',lambda _: 'source')
    write(run/'COSER-consumed.json',{'status':'started'})
    with pytest.raises(FileExistsError):cli.endpoint(data,run,'cpu')


def test_ner_missing_checkpoint_does_not_consume_confirmation(tmp_path,monkeypatch):
    """Preserve NER confirmation availability when an endpoint checkpoint is missing."""
    import campaign.cli as cli
    import campaign.ner_runner as runner
    from campaign.training import implementation_hash
    data=tmp_path/'data';data.mkdir();run=tmp_path/'run';run.mkdir()
    monkeypatch.setattr(cli,'bundle',lambda _: (data,{}, {},'syntax'))
    monkeypatch.setattr(runner,'verify_bundle',lambda _: {})
    monkeypatch.setattr(runner,'sha',lambda _: 'ner')
    write(run/'run-lock.json',dict(bundle_hash=fingerprint(dict(syntax_data='syntax',ner_data='ner')),implementation_hash=implementation_hash(),device='cpu'))
    write(run/'NER-decision.json',dict(endpoint=3))
    with pytest.raises(ValueError,match='Missing endpoint checkpoint'):runner.confirm_ner(data,data,run,'cpu')
    assert not (run/'NER-confirmation-consumed.json').exists()


def test_runtime_guard_allows_explicit_checkpoint_resume(tmp_path,monkeypatch):
    """Stop slow fresh training once and allow explicit continuation from its checkpoint."""
    import campaign.training as training
    from types import SimpleNamespace
    rows=[dict(id=str(i),text='x',words=['x']) for i in range(40)]
    schedule=[dict(source='ud',indices=[i],view='original') for i in range(40)]
    pkg=SimpleNamespace(steps=0,lm=None,base_digest='base',seed=42,device='cpu')
    def update(rows):
        """Record processed rows and advance a deterministic test optimizer or counter."""
        pkg.steps+=1;return dict(loss=1)
    pkg.update=update
    monkeypatch.setattr(training,'capture',lambda package,meta:dict(meta=meta))
    monkeypatch.setattr(training,'restore',lambda package,state:state['meta'])
    monkeypatch.setattr(training,'base_hash',lambda _: 'base')
    monkeypatch.setattr(training,'evaluate',lambda *_: {})
    clock=iter([0,1000,2000,3000]);monkeypatch.setattr(training.time,'perf_counter',lambda:next(clock))
    with pytest.raises(RuntimeError,match='Runtime guard'):
        training.run_epochs(pkg,tmp_path,{'1':schedule},{'ud':rows},[],set(),[1],'data')
    saved=torch.load(tmp_path/'latest.pt',weights_only=True)
    assert saved['meta']['cursor']==20 and pkg.steps==20
    training.run_epochs(pkg,tmp_path,{'1':schedule},{'ud':rows},[],set(),[1],'data')
    assert pkg.steps==40


def test_h_gate_rejects_new_keep_damage_even_with_equal_counts(tmp_path):
    """Reject newly damaged KEEP identities hidden by equal aggregate harm counts."""
    from campaign.cli import h_decision
    def result(harm,repairs):
        """Construct paired dev predictions with controlled KEEP damage."""
        predictions=[];metrics={}
        for lang in LANGUAGES:
            metrics[lang]=dict(complete_repairs=repairs,repair_rows=10,deletion_harmful_keep=1)
            predictions.append(dict(language=lang,treebank='primary',id='ordinary',counts=dict(tokens=10,las_correct=9)))
            predictions.append(dict(language=lang,treebank='primary',id='punctuation-only',counts={}))
            for identity in ('keep-a','keep-b'):
                predictions.append(dict(language=lang,treebank=None,id=identity,counts={},deletion=dict(harmful_keep=identity==harm)))
        return dict(predictions=predictions,metrics=metrics)
    primary={(l,'primary',i) for l in LANGUAGES for i in ('ordinary','punctuation-only')}
    control=result('keep-a',1);mix=result('keep-b',2)
    write(tmp_path/'H-control-seed42/epoch7-evaluation.json',control)
    write(tmp_path/'parent-seed42-evaluation.json',control)
    write(tmp_path/'H-mix-seed42/epoch7-evaluation.json',mix)
    decision=h_decision(tmp_path,[42],primary)
    assert not decision['passed'] and len(decision['seeds'][0]['new_harmful_keep'])==3
    write(tmp_path/'H-mix-seed42/epoch7-evaluation.json',result('keep-a',2))
    assert h_decision(tmp_path,[42],primary)['passed']



def test_ner_period_reduction_preserves_unknown_offsets():
    """Reject period/whitespace removal that would invalidate an unknown-region span."""
    from campaign.ner_runner import ner_view
    row=normalize_row(dict(text='Ana .',spans=[],annotation_complete=False,unknown_spans=[dict(start=0,end=4)]))
    out=ner_view(row,'punctuation_reduced')
    assert out['text']==row['text'] and out['unknown_spans']==row['unknown_spans']
    assert out['augmentation_rejected']=='Removed suffix overlaps annotation'
    assert row.get('augmentation_rejected') is None


def test_resume_restores_epoch_statistics_and_replaces_history(tmp_path,monkeypatch):
    """Preserve cumulative statistics and avoid duplicate history after an interrupted save."""
    from types import SimpleNamespace
    import campaign.training as training
    rows=[dict(id=str(i),text='x',words=['x'],augmentation_rejected='rejected') for i in range(3)]
    schedule=[dict(source='ud',indices=[i],view='original') for i in range(3)]
    pkg=SimpleNamespace(steps=1,lm=None,base_digest='base',seed=42,device='cpu')
    calls=[]
    def update(batch):
        """Record processed rows and advance a deterministic test optimizer or counter."""
        calls.append(batch[0]['id']);pkg.steps+=1
        return dict(loss=float(batch[0]['id'])+1)
    pkg.update=update
    monkeypatch.setattr(training,'capture',lambda package,meta:dict(meta=meta))
    monkeypatch.setattr(training,'restore',lambda package,state:state['meta'])
    monkeypatch.setattr(training,'base_hash',lambda _: 'base')
    monkeypatch.setattr(training,'evaluate',lambda *_: {})
    # Simulate a saved first batch with its loss and rejection already counted.
    training.save(tmp_path/'latest.pt',dict(meta=dict(epoch=1,cursor=1,complete=False,smoke=True,bundle_hash='data',backend='cpu',plan_hash=fingerprint(schedule),loss_sum=1.,augmentation_rejections={'rejected':1})))
    real_save=training.save
    def crash_after_history(path,state):
        """Simulate interruption between history replacement and final checkpoint save."""
        if Path(path).name=='latest.pt' and state['meta']['complete']:
            raise RuntimeError('interrupted after history write')
        real_save(path,state)
    monkeypatch.setattr(training,'save',crash_after_history)
    with pytest.raises(RuntimeError,match='interrupted after history'):
        training.run_epochs(pkg,tmp_path,{'1':schedule},{'ud':rows},[],set(),[1],'data',smoke=True)
    monkeypatch.setattr(training,'save',real_save)
    training.run_epochs(pkg,tmp_path,{'1':schedule},{'ud':rows},[],set(),[1],'data',smoke=True)
    history=read(tmp_path/'history.json')
    assert calls==['1','2'] and len(history)==1
    assert history[0]['mean_loss']==2. and history[0]['batches_completed']==3
    assert history[0]['augmentation_rejections']=={'rejected':3}



@pytest.mark.parametrize('heads,labels', [
    ([0,3,0],['root','reparandum','root']),
    ([3,3,0],['root','reparandum','root']),
    ([3,3,0],['nsubj','reparandum','obj']),
    ([3,3,0],['unknown','reparandum','root']),
])
def test_final_repair_rejects_forests_and_mismatched_root_labels(heads,labels):
    """Fail open on multi-root forests, wrong root relations and unknown labels."""
    row=example('I write edit',['I','write','edit'],heads,labels)
    out=repair(input_only(row),heads,labels)
    assert out['text']==row['text'] and out['edits']==[] and out['error']


def test_layer12_features_calls_only_the_selected_prefix(monkeypatch):
    """Check that the retained feature path requests block 12 and keeps gradients."""
    import campaign.encoder as encoder
    from types import SimpleNamespace
    package=encoder.Layer12Features(None,SimpleNamespace(model='encoder'), 'cpu')
    package.inputs=lambda _: ({'input_ids':torch.tensor([[1,2]]),'attention_mask':torch.ones(1,2)},torch.tensor([[[.5,.5]]]))
    seen=[]
    def prefix(model,input_ids,attention_mask,blocks):
        """Record the selected encoder depth and return differentiable test features."""
        seen.append((model,blocks));return torch.tensor([[[2.,4.],[4.,8.]]],requires_grad=True)
    monkeypatch.setattr(encoder,'prefix_states',prefix)
    value=package([{'words':['x']}])
    assert seen==[('encoder',12)] and value.tolist()==[[[3.,6.]]]
    assert value.requires_grad


@pytest.mark.parametrize('empty_counts',[{},dict(tokens=0,las_correct=0)])
def test_paired_effect_zero_token_rows(empty_counts):
    """Legacy omitted zeros and explicit zeros yield the same scoreable bootstrap."""
    control=[dict(language=l,treebank='dev',id='scored',counts=dict(tokens=10,las_correct=8)) for l in LANGUAGES]
    feature=copy.deepcopy(control)
    for row in feature:row['counts']['las_correct']=9
    expected=paired_effect(control,feature,samples=40)
    for l in LANGUAGES:
        zero=dict(language=l,treebank='dev',id='punctuation',counts=empty_counts.copy())
        control.append(zero);feature.append(copy.deepcopy(zero))
    actual=paired_effect(control,feature,samples=40)
    assert actual=={**expected,'zero_token_rows':dict.fromkeys(LANGUAGES,1)}
    assert actual['macro_pp']==10 and actual['macro_ci95_pp']==[10,10]


def test_paired_effect_rejects_empty_language_and_mismatched_masks():
    """Do not hide missing language evidence or one-sided punctuation masks."""
    zero=dict(language='en',treebank='dev',id='punctuation',counts={})
    scored=dict(language='fr',treebank='dev',id='scored',counts=dict(tokens=1,las_correct=1))
    with pytest.raises(ValueError,match='Each language needs scored tokens'):
        paired_effect([zero,scored],[copy.deepcopy(zero),copy.deepcopy(scored)])
    other=copy.deepcopy(zero);other['counts']=dict(tokens=1,las_correct=0)
    with pytest.raises(ValueError,match='Unpaired scoring masks'):
        paired_effect([zero],[other])
