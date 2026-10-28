import os
from pathlib import Path
os.environ.setdefault('HF_HOME',str(Path('artifacts/hf-cache').resolve()))
os.environ.setdefault('HF_HUB_OFFLINE','1')
os.environ.setdefault('TOKENIZERS_PARALLELISM','false')
import torch
from torch import nn
from torch.nn import functional as F
from transformers import AutoTokenizer, AutoModelForMaskedLM
from campaign.common import *
from campaign.adapters import install_adapters, adapter_state, load_adapter_state
from campaign.encoder import Layer12Features
from campaign.encoder import base_hash
from campaign.trees import ud_targets
from campaign.parser import ParserHead, loss_for
from campaign.trees import RELATIONS


class GrammarHead(nn.Module):
    def __init__(self,vocab):
        """Initialize the task module from frozen inputs and checked configuration."""
        super().__init__();self.vocab=vocab
        self.layers=nn.ModuleDict({k:nn.Linear(384,len(v)) for k,v in vocab.items()})
    def forward(self,x):
        """Produce logits for each train-only grammar inventory."""
        return {k:layer(x) for k,layer in self.layers.items()}


def grammar_targets(rows,width,vocab,device):
    """Mask unknown morphology while preserving observed absent values."""
    result={k:torch.full((len(rows),width),-100,dtype=torch.long,device=device) for k in vocab}
    lookup={k:{v:i for i,v in enumerate(values)} for k,values in vocab.items()}
    for i,r in enumerate(rows):
        for j,pos in enumerate(r.get('upos',[])):result['upos'][i,j]=lookup['upos'].get(pos,-100)
        for j,(f,observed) in enumerate(zip(r.get('morph',[]),r.get('morph_observed',[]))):
            for a in ATTRIBUTES:
                if observed[a]:result[a][i,j]=lookup[a].get(f.get(a,ABSENT),-100)
    return result


def masked_ce(logits,targets):
    """Compute cross-entropy only for observed targets, or differentiable zero."""
    mask=targets!=-100
    return F.cross_entropy(logits[mask],targets[mask]) if mask.any() else logits.sum()*0


class Package:
    def __init__(self,task,protocol,vocab,seed,device,feature=False,teacher=None):
        """Initialize the task module from frozen inputs and checked configuration."""
        self.task,self.device,self.vocab,self.seed=task,device,vocab,seed
        self.protocol=protocol;self.teacher=teacher;self.feature=feature
        require(protocol['block']==12,'This campaign uses raw block 12')
        torch.manual_seed(seed)
        self.tokenizer=AutoTokenizer.from_pretrained(protocol['model'],revision=protocol['revision'],local_files_only=True)
        self.lm=AutoModelForMaskedLM.from_pretrained(protocol['model'],revision=protocol['revision'],local_files_only=True,attn_implementation='eager').eval().requires_grad_(False)
        self.base_digest=base_hash(self.lm)
        install_adapters(self.lm.model,blocks=12,rank=4,alpha=8)
        self.lm.to(device);self.online=Layer12Features(self.tokenizer,self.lm,device)
        torch.manual_seed(seed)
        if task=='grammar':self.head=GrammarHead(vocab)
        elif task=='syntax':self.head=ParserHead(384,RELATIONS,arc_dim=128,label_dim=64,dropout=.2)
        elif task=='ner':self.head=nn.Linear(384,len(BIO))
        else:raise ValueError(task)
        self.head.to(device)
        self.fusion=None
        if feature:
            require(task=='syntax' and teacher is not None,'Syntax feature arm requires frozen teacher')
            self.fusion=nn.Linear(sum(len(x) for x in vocab.values()),384,bias=False).to(device)
            nn.init.zeros_(self.fusion.weight)
        self.lp=[p for p in self.lm.parameters() if p.requires_grad]
        self.hp=list(self.head.parameters())+(list(self.fusion.parameters()) if self.fusion is not None else [])
        self.opt=torch.optim.AdamW([{'params':self.hp,'lr':.001},{'params':self.lp,'lr':.0001}],weight_decay=.01,betas=(.9,.999),eps=1e-8)
        self.steps=0

    def features(self,rows):
        """Read block-12 word states and optionally fuse frozen grammar probabilities."""
        x=self.online(rows)
        if self.fusion is not None:x=x+self.fusion(self.teacher.probabilities(rows).to(self.device))
        return x

    def update(self,rows):
        """Perform one checked optimizer step while preventing base-weight gradients."""
        self.head.train();self.opt.zero_grad(set_to_none=True)
        x=self.features(rows)
        if self.task=='syntax':
            mask,parents,rels=[t.to(self.device) for t in ud_targets(rows,x.shape[1],RELATIONS)]
            a,r=self.head(x,mask,gold_heads=parents);loss=loss_for(a,r,parents,rels,mask)
        elif self.task=='grammar':
            logits=self.head(x);targets=grammar_targets(rows,x.shape[1],self.vocab,self.device)
            observed=[a for a in ATTRIBUTES if (targets[a]!=-100).any()]
            morph=torch.stack([masked_ce(logits[a],targets[a]) for a in observed]).mean() if observed else x.sum()*0
            loss=masked_ce(logits['upos'],targets['upos'])+morph
        else:
            targets=torch.full(x.shape[:2],-100,dtype=torch.long,device=self.device)
            for i,r in enumerate(rows):targets[i,:len(r['words'])]=torch.tensor(r['ner_targets'],device=self.device)
            loss=masked_ce(self.head(x),targets)
        require(torch.isfinite(loss).item(),'Nonfinite loss')
        loss.backward()
        require(all(p.grad is None for p in self.lm.parameters() if not p.requires_grad),'Base received gradients')
        require(any(p.grad is not None and p.grad.abs().sum()>0 for p in self.lp),'Missing adapter gradients')
        norm=torch.nn.utils.clip_grad_norm_(self.hp+self.lp,5,error_if_nonfinite=True)
        self.opt.step();self.steps+=1
        return dict(loss=loss.item(),gradient_norm=norm.item(),steps=self.steps)


class Teacher:
    def __init__(self,checkpoint,protocol,vocab,seed,device,allow_smoke=False):
        """Initialize the task module from frozen inputs and checked configuration."""
        state=torch.load(checkpoint,map_location='cpu',weights_only=True)
        require(state['meta']['task']=='grammar' and state['meta']['seed']==seed,'Wrong grammar teacher')
        require(allow_smoke or (state['meta']['epoch']==5 and state['meta']['complete'] and not state['meta']['smoke']),'Teacher must be completed G5')
        self.package=Package('grammar',protocol,vocab,seed,device)
        from campaign.training import restore
        restore(self.package,state,restore_rng=False)
        self.package.lm.requires_grad_(False);self.package.head.requires_grad_(False).eval()
        self.digest=sha(checkpoint);self.cache={};self.vocab=vocab
    @torch.no_grad()
    def probabilities(self,rows):
        """Cache detached grammar probabilities by teacher and transformed input."""
        keys=[fingerprint(dict(teacher=self.digest,vocab=self.vocab,words=r['words'],text=r['text'],surface=r.get('surface_ud_map'),augmentation=r.get('augmentation','original'))) for r in rows]
        missing=[i for i,k in enumerate(keys) if k not in self.cache]
        if missing:
            selected=[rows[i] for i in missing]
            logits=self.package.head(self.package.online(selected))
            values=torch.cat([logits[k].softmax(-1) for k in self.vocab],dim=-1).cpu()
            for j,i in enumerate(missing):self.cache[keys[i]]=values[j,:len(rows[i]['words'])].clone()
        return nn.utils.rnn.pad_sequence([self.cache[k] for k in keys],batch_first=True)
