"""Shared full-state runner. All randomness beyond dropout is in frozen plans."""
import copy
import time
from pathlib import Path
import torch
from campaign.common import *
from campaign.surface import view
from campaign.network import Package
from adapters import adapter_state,load_adapter_state
from lora_syntax_only import base_hash
from campaign.metrics import evaluate


def implementation_hash():
    return fingerprint({str(p):sha(p) for p in sorted(Path('campaign').glob('*.py'))} | {p:sha(p) for p in ('adapters.py','model.py','syntax_layers_10_11_12_v1.py','lora_syntax_only.py','data.py','english_diversity_pilot.py','mechanical_tree_repair.py','lora_syntax_continue.py')})


def capture(package,meta):
    return dict(meta={**meta, 'task':package.task,'seed':package.seed,'feature':package.feature,
        'teacher_hash':package.teacher.digest if package.teacher else None,
        'implementation_hash':implementation_hash(),'protocol_hash':fingerprint(package.protocol),
        'base_hash':package.base_digest,'inventory':package.vocab,'steps':package.steps},
        head={k:v.detach().cpu().clone() for k,v in package.head.state_dict().items()},
        fusion={k:v.detach().cpu().clone() for k,v in package.fusion.state_dict().items()} if package.fusion is not None else None,
        adapters=adapter_state(package.lm.model),optimizer=copy.deepcopy(package.opt.state_dict()),
        rng_cpu=torch.get_rng_state(),rng_mps=torch.mps.get_rng_state() if package.device=='mps' else None)


def restore(package,state,restore_rng=True):
    m=state['meta']
    require(m['task']==package.task and m['seed']==package.seed and m['feature']==package.feature,'Checkpoint task/seed/feature mismatch')
    require(m['inventory']==package.vocab and m['protocol_hash']==fingerprint(package.protocol),'Checkpoint input mismatch')
    require(m['implementation_hash']==implementation_hash(),'Implementation changed; explicit new run required')
    require(m['base_hash']==package.base_digest,'Checkpoint base changed')
    require(m['teacher_hash']==(package.teacher.digest if package.teacher else None),'Teacher changed')
    package.head.load_state_dict(state['head']);load_adapter_state(package.lm.model,state['adapters'])
    if package.fusion is not None:package.fusion.load_state_dict(state['fusion'])
    package.opt.load_state_dict(state['optimizer']);package.steps=m['steps']
    # Attribute heads with missing supervision do not receive a gradient on every
    # batch; their AdamW counters legitimately differ from the global update count.
    require(all(0<int(s['step'].item())<=package.steps for s in package.opt.state.values()),'Optimizer counters inconsistent')
    if restore_rng:
        torch.set_rng_state(state['rng_cpu'].cpu())
        if package.device=='mps':
            require(state['rng_mps'] is not None,'Cannot resume stochastic trajectory across backends')
            torch.mps.set_rng_state(state['rng_mps'].cpu())
    return m


def save(path,state):
    path=Path(path);tmp=path.with_suffix('.tmp');torch.save(state,tmp);tmp.replace(path)


def run_epochs(package,output,plans,pools,dev,forbidden,epochs,bundle_hash,resume=None,smoke=False,max_batches=None):
    output=Path(output);output.mkdir(parents=True,exist_ok=True)
    require(smoke or max_batches is None,'Partial-step limits are smoke-only')
    latest=output/'latest.pt'
    state_path=latest if latest.exists() else resume
    meta=None
    if state_path:
        state=torch.load(state_path,map_location='cpu',weights_only=True);meta=restore(package,state)
        require(meta['bundle_hash']==bundle_hash and meta['smoke']==smoke,'Resume data/mode mismatch')
    history=read(output/'history.json') if (output/'history.json').exists() else []
    for epoch in epochs:
        if meta and (epoch<meta['epoch'] or epoch==meta['epoch'] and meta['complete']):continue
        schedule=plans[str(epoch)]
        if smoke and max_batches is not None:schedule=schedule[:max_batches]
        start=meta['cursor'] if meta and epoch==meta['epoch'] and not meta['complete'] else 0
        if not start:torch.manual_seed(package.seed*1000+epoch)
        started=time.perf_counter()
        rejections=CounterLike(meta['augmentation_rejections'] if start else {})
        loss_sum=meta['loss_sum'] if start else 0
        def checkpoint(cursor,complete):
            return capture(package,dict(epoch=epoch,cursor=cursor,complete=complete,smoke=smoke,bundle_hash=bundle_hash,
                plan_hash=fingerprint(schedule),backend=package.device,loss_sum=loss_sum,augmentation_rejections=dict(rejections)))
        if meta and epoch==meta['epoch'] and not meta['complete']:
            require(meta['plan_hash']==fingerprint(schedule) and meta['backend']==package.device,'Resume schedule/backend changed')
        for index in range(start,len(schedule)):
            slot=schedule[index];rows=[view(pools[slot['source']][i],slot['view'],forbidden) for i in slot['indices']]
            for r in rows:
                if r.get('augmentation_rejected'):rejections[r['augmentation_rejected']]+=1
            result=package.update(rows);loss_sum+=result['loss']
            if (index+1)%50==0:save(latest,checkpoint(index+1,False))
            if start==0 and index+1==20 and not smoke:
                estimated=(time.perf_counter()-started)*len(schedule)/20
                if estimated>600:
                    save(latest,checkpoint(index+1,False));raise RuntimeError('Runtime guard: saved full resume; investigate before continuing')
        require(base_hash(package.lm)==package.base_digest,'Base weights changed')
        final=checkpoint(len(schedule),True)
        save(output/f'epoch{epoch}.pt',final)
        save(latest,checkpoint(len(schedule),False))
        metrics=evaluate(package,dev)
        write(output/f'epoch{epoch}-evaluation.json',metrics)
        entry=dict(epoch=epoch,steps=package.steps,batches_completed=len(schedule),
            mean_loss=loss_sum/max(len(schedule),1),seconds_this_invocation=time.perf_counter()-started,augmentation_rejections=dict(rejections))
        history=[h for h in history if h['epoch']!=epoch]+[entry]
        write(output/'history.json',history)
        save(latest,final)
        print('EPOCH',output.name,entry,flush=True);meta=final['meta']
    return output/f'epoch{epochs[-1]}.pt'


class CounterLike(dict):
    def __missing__(self,key):return 0
