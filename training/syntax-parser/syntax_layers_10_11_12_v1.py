"""One matched fresh-base epoch at depth10/12, reusing saved depth11 epoch1."""
import os
from pathlib import Path
os.environ.setdefault('HF_HOME',str(Path('artifacts/hf-cache').resolve()))
os.environ.setdefault('HF_HUB_OFFLINE','1')
os.environ.setdefault('TOKENIZERS_PARALLELISM','false')
import argparse,hashlib,math,time
from collections import defaultdict
import torch
from transformers import AutoModelForMaskedLM,AutoTokenizer
from adapters import (LoRALinear,install_adapters,adapter_state,load_adapter_state,
                      set_adapters,prefix_states,pool_words)
from adapter_pilot import mask_probe
from english_diversity_pilot import read,digest,ud_targets
from lora_syntax_only import OnlineFeatures,load_groups,base_hash,sync
from model import ParserHead,batch_rows,decode,loss_for
from train import evaluate,score_counts,summarize
from data import RELATIONS,write_json
OLD=Path('artifacts/lora-syntax-only-v1')
CHECKPOINT=OLD/'lora-epoch1-weights.pt'

def tensor_hash(state):
 h=hashlib.sha256()
 for k,v in state.items():h.update(k.encode());h.update(v.detach().cpu().contiguous().numpy().tobytes())
 return h.hexdigest()

def uninstall(encoder):
 for layer in encoder.layers:
  for name in ['Wqkv','Wo']:
   m=getattr(layer.attn,name)
   if isinstance(m,LoRALinear):setattr(layer.attn,name,m.base)

def fresh_initialization(lm,depth,settings):
 uninstall(lm.model);torch.manual_seed(42);install_adapters(lm.model,blocks=depth,rank=4,alpha=8)
 # The historical head seed reset occurred independently after the frozen arm.
 torch.manual_seed(42);head=ParserHead(**settings)
 return head,adapter_state(lm.model)

class DepthFeatures(OnlineFeatures):
 def __init__(self,tokenizer,model,device,depth):super().__init__(tokenizer,model,device);self.depth=depth
 def __call__(self,rows):
  tokens,weights=self.inputs(rows)
  hidden=prefix_states(self.model.model,tokens['input_ids'],tokens['attention_mask'],blocks=self.depth)
  return torch.bmm(weights,hidden).half().float()

@torch.inference_mode()
def metric_details(head,cached,device):
 head.eval();counts=defaultdict(lambda:defaultdict(int));sentences=[];predictions=[]
 for start in range(0,len(cached),16):
  rows=cached[start:start+16];values,mask,_,_=batch_rows(rows,device);arcs,labels=head(values,mask)
  for i,r in enumerate(rows):
   h,l=decode(arcs[i],labels[i],len(r['words']),RELATIONS);c=score_counts(r,h,l)
   sentences.append({'id':r['id'],'treebank':r['treebank'],**c});predictions.append({'id':r['id'],'treebank':r['treebank'],'text':r['text'],'words':r['words'],'heads':h,'labels':l})
   for group in ['all',r['language'],r['treebank']]:
    for k,v in c.items():counts[group][k]+=v
 result={k:summarize(v) for k,v in counts.items()};languages={r['language'] for r in cached}
 result['macro_language_las']=sum(result[k]['las'] for k in languages)/len(languages)
 return result,sentences,predictions

@torch.inference_mode()
def assess(head,online,groups,out,arm,device):
 metrics={};sentences={}
 for name in ['dev','english_dev','gum_dev']:
  cached=online.cache(groups[name]);m,s,p=metric_details(head,cached,device)
  # Exact parity with the historical shared evaluator, including repair counts.
  assert m==evaluate(head,cached,16,device)
  metrics[name]=m;sentences[name]=s;write_json(out/f'{arm}-{name}-predictions.json',p)
 return metrics,sentences

@torch.inference_mode()
def latency(head,online,rows,device):
 head.eval()
 def one(row):
  values=online([row]);mask=torch.ones(values.shape[:2],dtype=torch.bool,device=device)
  a,l=head(values,mask);decode(a[0],l[0],len(row['words']),RELATIONS)
 for row in rows[:5]:one(row)
 times=[]
 for row in rows:
  sync(device);t=time.perf_counter();one(row);sync(device);times.append((time.perf_counter()-t)*1000)
 v=torch.tensor(times)
 return {'device':device,'batch_size':1,'threads':4,'scope':'Warm loaded tokenizer+prefix+word mean pooling+compact head+single-root CPU decode','warmups':5,'sentences':len(rows),'word_counts':[len(r['words']) for r in rows],'milliseconds':times,'median_ms':v.median().item(),'mean_ms':v.mean().item(),'p95_ms':v.quantile(.95).item()}

@torch.inference_mode()
def examples(head,online):
 rows=[{'words':x.split(),'text':x} for x in ['the cat the dog is eating','I want to write to edit the code']];result=[]
 head.eval()
 for row in rows:
  values=online([row]);a,l=head(values,torch.ones(values.shape[:2],dtype=torch.bool,device=values.device));h,r=decode(a[0],l[0],len(row['words']),RELATIONS)
  result.append({**row,'heads':h,'labels':r,'scope':'Previously exposed qualitative example; unscored, no tuning'})
 return result

def verify_historical():
 protocol=read(OLD/'protocol.json');v=read(OLD/'verification.json')
 for path,h in protocol['source_sha256'].items():assert digest(path)==h,path
 for name in ['lora-epoch1-weights.pt','lora-epoch1-resume.pt']:assert digest(OLD/name)==v['checkpoint_sha256'][name],name
 w=torch.load(CHECKPOINT,map_location='cpu',weights_only=True)
 assert w['epoch']==1 and w['protocol_sha256']==digest(OLD/'protocol.json') and w['settings']==protocol['head']
 assert len(w['adapters'])==44
 resume=torch.load(OLD/'lora-epoch1-resume.pt',map_location='cpu',weights_only=True)
 for section in ['head','adapters']:
  assert w[section].keys()==resume['weights'][section].keys()
  assert all(torch.equal(t,resume['weights'][section][k]) for k,t in w[section].items())
 assert {int(x['step']) for x in resume['optimizer']['state'].values()}=={1498}
 return protocol,v,w

def prepare(out):
 assert not out.exists();out.mkdir();torch.set_num_threads(2)
 historical,v,w=verify_historical();groups,sources=load_groups();order=historical['sample_orders'][0]
 assert order==torch.randperm(23957,generator=torch.Generator().manual_seed(4201)).tolist()
 assert sorted(order)==list(range(23957)) and len(order)==23957
 c=read('config.json');lm=AutoModelForMaskedLM.from_pretrained(c['model_id'],revision=c['model_revision'],local_files_only=True,attn_implementation='eager').eval().requires_grad_(False)
 assert base_hash(lm)==v['encoder_before_sha256'];initial={};reference_head,reference=fresh_initialization(lm,11,historical['head'])
 for depth in [10,11,12]:
  head,a=fresh_initialization(lm,depth,historical['head']);shared={k:t for k,t in a.items() if k in reference}
  assert all(torch.equal(t,reference[k]) for k,t in shared.items())
  assert all(torch.equal(t,reference_head.state_dict()[k]) for k,t in head.state_dict().items())
  assert all(torch.count_nonzero(t)==0 for k,t in a.items() if k.endswith('lora_B'))
  initial[depth]={'head':{k:t.detach().cpu().clone() for k,t in head.state_dict().items()},'adapters':a,'head_hash':tensor_hash(head.state_dict()),'adapter_hash':tensor_hash(a),'per_block_hashes':{str(i+1):tensor_hash({k:t for k,t in a.items() if k.startswith(f'layers.{i}.')}) for i in range(depth)},'adapter_parameters':sum(t.numel() for t in a.values()),'head_parameters':sum(t.numel() for t in head.state_dict().values())}
 torch.save(initial,out/'initialization.pt');del lm,w
 paths=list(sources)+[Path(__file__),Path('tests/test_syntax_layers_10_11_12_v1.py')]+[OLD/n for n in ['protocol.json','history.json','verification.json','lora-epoch1-weights.pt','lora-epoch1-resume.pt']]
 source={**historical['source_sha256'],**{str(p):digest(p) for p in paths}}
 protocol={'question':'Practical neighboring prefix depths10/11/12 after one fresh-base UD-only LoRA epoch','base':{'model_id':c['model_id'],'revision':c['model_revision'],'sha256':v['encoder_before_sha256']},'device':'mps','threads':4,'seed':42,'training_rng':4201,'head':historical['head'],'optimizer':historical['optimizer'],'batch_size':16,'epochs':1,'updates_per_new_arm':1498,'train_new_depths':[10,12],'reuse_baseline':{'checkpoint':str(CHECKPOINT),'sha256':digest(CHECKPOINT),'epoch':1,'historical_device':historical['device'],'reevaluate_before_training':True},'sampling':'Exact original23957 UD rows each once, historical epoch1 order; no local/grammar inputs or losses','representation':'Raw output after one-based depth, before final norm; mean subwords then FP16 half→float roundtrip','adapter_placement':'Fresh rank4 alpha8 Wqkv/Wo prefix1..depth; practical depth comparison changes adapters92160/101376/110592 and gradient depth, not pure fixed-parameter readout','initialization':'CPU seed42 immediately before adapter installation, independently reset42 before fresh head; common block A/B and all head tensors exactly recreated/hashed against reference11; no trained11 initialization in new arms','initialization_sha256':digest(out/'initialization.pt'),'initial_hashes':{d:{k:z[k] for k in ['head_hash','adapter_hash','per_block_hashes','adapter_parameters','head_parameters']} for d,z in initial.items()},'order':order,'split_ids':{k:[{'treebank':r['treebank'],'id':r['id']} for r in rs] for k,rs in groups.items()},'source_sha256':source,'metric':'Identical gold-word UAS/LAS excludes gold PUNCT; UD repair precision/recall/F1; dev400 English500 GUM1555 overlap, not three independent estimates','endpoint':'Fixed one epoch, one seed, no depth search or new test use. Baseline replay must match history exactly before new training; otherwise stop and report.','benchmark_policy':'First20actual updates contribute to fixed1498; report projected remaining cost. If estimate exceeds10min per arm, stop with resumable state for parent decision.','latency':'Same first40 English-dev rows,5warmups,batch1 tokenizer+prefix+pool+head+one-root CPU decoder; per-arm median/mean/p95; descriptive, sequential order can confound tails','limits':['One seed and one epoch; adapter count changes with depth.','Existing dev repeatedly exposed; repair positives1/4/80 too sparse for deletion safety.','Trained11baseline reused with exact historical procedure and backend replay; new10/12 arms fresh pretrained base plus fresh identical common-prefix/head initialization.']}
 write_json(out/'protocol.json',protocol);write_json(out/'prepared.json',{'historical_sources_verified':len(historical['source_sha256']),'historical_checkpoint_metadata_verified':True,'original_resume_steps':1498,'common_prefix_and_head_initialization_exact':True,'initialization_sha256':digest(out/'initialization.pt'),'selection_sizes':{k:len(v) for k,v in groups.items()}})
 print('PREPARED',digest(out/'protocol.json'),protocol['initial_hashes'],flush=True)

def run(out):
 assert (out/'protocol.json').exists() and not (out/'run-started.json').exists();started=time.perf_counter();p=read(out/'protocol.json');torch.set_num_threads(4)
 assert torch.backends.mps.is_available(),'Original MPS backend unavailable; inform parent instead of silently changing backend'
 for path,h in p['source_sha256'].items():assert digest(path)==h,path
 assert digest(out/'initialization.pt')==p['initialization_sha256']
 write_json(out/'run-started.json',{'device':'mps','protocol_sha256':digest(out/'protocol.json')})
 groups,_=load_groups();assert all([{'treebank':r['treebank'],'id':r['id']} for r in rs]==p['split_ids'][k] for k,rs in groups.items())
 init=torch.load(out/'initialization.pt',map_location='cpu',weights_only=True);c=read('config.json')
 tok=AutoTokenizer.from_pretrained(c['model_id'],revision=c['model_revision'],local_files_only=True)
 def fresh():return AutoModelForMaskedLM.from_pretrained(c['model_id'],revision=c['model_revision'],local_files_only=True,attn_implementation='eager').eval().requires_grad_(False)
 cpu=fresh();original_hash=base_hash(cpu);assert original_hash==p['base']['sha256'];original_logits=mask_probe(cpu,tok);del cpu
 result={};verification={};latencies={};examples_all={}
 # Exact replay first; this is not a fresh baseline retraining.
 lm=fresh();install_adapters(lm.model,blocks=11);w=torch.load(CHECKPOINT,map_location='cpu',weights_only=True);load_adapter_state(lm.model,w['adapters']);lm.to('mps');head=ParserHead(**w['settings']).to('mps');head.load_state_dict(w['head']);online=DepthFeatures(tok,lm,'mps',11)
 t=time.perf_counter();metrics,details=assess(head,online,groups,out,'depth11-saved','mps');expected=read(OLD/'history.json')['lora'][0]['metrics']
 write_json(out/'baseline-replay.json',{'metrics':metrics,'historical':expected,'exact':metrics==expected,'seconds':time.perf_counter()-t})
 assert metrics==expected,'Saved11baseline does not exactly replay historical MPS counters: stop before new training and report'
 result['11']={'metrics':metrics,'sentence_counts':details,'trained_now':False,'historical_training_seconds':read(OLD/'history.json')['lora'][0]['training_seconds'],'adapter_parameters':init[11]['adapter_parameters'],'head_parameters':init[11]['head_parameters']};latencies['11']=latency(head,online,groups['english_dev'][:40],'mps');examples_all['11']=examples(head,online)
 write_json(out/'results-progress.json',result);write_json(out/'latencies-progress.json',latencies);print('BASELINE11_EXACT',flush=True)
 del lm,head,online,w;torch.mps.empty_cache()
 for depth in p['train_new_depths']:
  lm=fresh();assert base_hash(lm)==original_hash;head,a=fresh_initialization(lm,depth,p['head'])
  assert tensor_hash(a)==init[depth]['adapter_hash'] and tensor_hash(head.state_dict())==init[depth]['head_hash']
  assert all(torch.equal(t,init[depth]['adapters'][k]) for k,t in a.items())
  assert torch.equal(mask_probe(lm,tok),original_logits),'ZeroBinit must match base MLM exactly on fresh CPU'
  lm.to('mps');head.to('mps');online=DepthFeatures(tok,lm,'mps',depth)
  with torch.no_grad():
   probe=groups['english_dev'][:4];tokens,weights=online.inputs(probe);raw=prefix_states(lm.model,tokens['input_ids'],tokens['attention_mask'],blocks=depth)
   captured={};hook=lm.model.layers[depth-1].register_forward_hook(lambda m,a,o:captured.update(raw=o))
   _=prefix_states(lm.model,tokens['input_ids'],tokens['attention_mask'],blocks=depth);hook.remove();assert torch.equal(raw,captured['raw'])
   legacy=pool_words(raw,[tokens.word_ids(i) for i in range(4)],[len(r['words']) for r in probe]);fast=torch.bmm(weights,raw).half().float();pool_delta=(legacy-fast).abs().max().item();assert torch.allclose(legacy,fast,atol=.002,rtol=.002)
  hp=list(head.parameters());ap=[v for v in lm.parameters() if v.requires_grad];params=hp+ap
  assert sum(v.numel() for v in ap)==init[depth]['adapter_parameters']
  optimizer=torch.optim.AdamW([{'params':hp,'lr':.001},{'params':ap,'lr':.0001}],weight_decay=.01)
  torch.manual_seed(4201);head.train();sync('mps');t=time.perf_counter();losses=[];seen=[];bench=None
  print('TRAIN_START',depth,'freshbase1498updates',flush=True)
  for step,start in enumerate(range(0,len(p['order']),16),1):
   ids=p['order'][start:start+16];seen+=ids;rows=[groups['ud'][i] for i in ids];optimizer.zero_grad(set_to_none=True)
   values=online(rows);mask,h,l=[v.to('mps') for v in ud_targets(rows,values.shape[1],RELATIONS)];arcs,labels=head(values,mask,gold_heads=h);loss=loss_for(arcs,labels,h,l,mask);assert torch.isfinite(loss);loss.backward()
   if step==1:
    assert any(v.grad is not None and v.grad.abs().sum()>0 for v in ap)
    assert all(v.grad is None for v in lm.parameters() if not v.requires_grad)
   torch.nn.utils.clip_grad_norm_(params,5,error_if_nonfinite=True);optimizer.step();losses.append(loss.item())
   if step==20:
    sync('mps');elapsed=time.perf_counter()-t;bench={'depth':depth,'updates':20,'seconds':elapsed,'projected1498_seconds':elapsed*1498/20};write_json(out/f'depth{depth}-benchmark.json',bench);print('BENCHMARK',bench,flush=True)
    if bench['projected1498_seconds']>600:
     torch.save({'head':head.state_dict(),'adapters':adapter_state(lm.model),'optimizer':optimizer.state_dict(),'rng_cpu':torch.get_rng_state(),'rng_mps':torch.mps.get_rng_state(),'updates':20},out/f'depth{depth}-benchmark-paused.pt')
     raise RuntimeError('Projected epoch exceeds10min; resumable20-update state saved, inform parent before continuing')
   if step%100==0:
    print('TRAIN',depth,step,'/1498','loss',sum(losses)/len(losses),'seconds',time.perf_counter()-t,flush=True);write_json(out/f'depth{depth}-progress.json',{'updates':step,'mean_loss':sum(losses)/len(losses),'seconds':time.perf_counter()-t})
  assert step==1498 and sorted(seen)==list(range(23957));sync('mps');training_seconds=time.perf_counter()-t
  assert {int(s['step']) for s in optimizer.state.values()}=={1498}
  head.eval();weights={'head':{k:v.detach().cpu().clone() for k,v in head.state_dict().items()},'settings':p['head'],'adapters':adapter_state(lm.model),'epoch':1,'depth':depth,'protocol_sha256':digest(out/'protocol.json')}
  torch.save(weights,out/f'depth{depth}-epoch1-weights.pt');torch.save({'weights':weights,'optimizer':optimizer.state_dict()},out/f'depth{depth}-epoch1-resume.pt')
  t_eval=time.perf_counter();m,d=assess(head,online,groups,out,f'depth{depth}','mps');result[str(depth)]={'metrics':m,'sentence_counts':d,'trained_now':True,'loss':sum(losses)/len(losses),'training_seconds':training_seconds,'evaluation_seconds':time.perf_counter()-t_eval,'updates':1498,'rows_seen_once':len(seen),'adapter_parameters':sum(v.numel() for v in ap),'head_parameters':sum(v.numel() for v in hp),'benchmark':bench}
  latencies[str(depth)]=latency(head,online,groups['english_dev'][:40],'mps');examples_all[str(depth)]=examples(head,online)
  lm.cpu();set_adapters(lm.model,False);assert base_hash(lm)==original_hash
  roundtrip=mask_probe(lm,tok);delta=(roundtrip-original_logits).abs().max().item()
  # Historical device roundtrip may cause small logits differences without weight changes.
  fresh_cpu=fresh();install_adapters(fresh_cpu.model,blocks=depth);load_adapter_state(fresh_cpu.model,weights['adapters']);set_adapters(fresh_cpu.model,False)
  assert base_hash(fresh_cpu)==original_hash and torch.equal(mask_probe(fresh_cpu,tok),original_logits)
  verification[str(depth)]={'base_hash_unchanged':True,'fresh_cpu_disabled_mlm_exact':True,'device_roundtrip_mlm_max_abs':delta,'head_initialization_exact':True,'adapter_initialization_exact':True,'prefix_hook_raw_exact':True,'pooling_max_abs':pool_delta,'frozen_base_no_grad':True,'optimizer_steps':1498,'whole_ud_once':True}
  write_json(out/'results-progress.json',result);write_json(out/'latencies-progress.json',latencies);write_json(out/'verification-progress.json',verification);print('EVAL',depth,{k:v['all'] for k,v in m.items()},flush=True)
  del lm,head,online,fresh_cpu,hp,ap,params,optimizer,weights;torch.mps.empty_cache()
 for path,h in p['source_sha256'].items():assert digest(path)==h,path
 assert digest(out/'initialization.pt')==p['initialization_sha256']
 write_json(out/'results.json',result);write_json(out/'latencies.json',latencies);write_json(out/'examples-unscored.json',examples_all)
 write_json(out/'verification.json',{'depths':verification,'baseline11_historical_exact':True,'source_and_initialization_hashes_unchanged':True,'new_training_updates':2996,'new_training_sentences':47914,'device':'mps','original_device':'mps','test_not_evaluated':True,'total_wall_seconds':time.perf_counter()-started,'checkpoint_sha256':{f.name:digest(f) for f in out.glob('*epoch1-*.pt')}})
 print('COMPLETE',time.perf_counter()-started,flush=True)

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--output',type=Path,required=True);ap.add_argument('--prepare',action='store_true');a=ap.parse_args()
 prepare(a.output) if a.prepare else run(a.output)
if __name__=='__main__':main()
