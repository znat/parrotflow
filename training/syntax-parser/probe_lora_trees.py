"""Qualitative sentence comparison, without training or accuracy claims."""
import os
from pathlib import Path
os.environ.setdefault('HF_HOME', str(Path('artifacts/hf-cache').resolve()))
os.environ.setdefault('HF_HUB_OFFLINE', '1')
os.environ.setdefault('TOKENIZERS_PARALLELISM', 'false')
import json
import hashlib
import torch
from transformers import AutoModelForMaskedLM, AutoTokenizer
from adapters import install_adapters, load_adapter_state, set_adapters
from data import RELATIONS
from lora_syntax_only import OnlineFeatures
from model import ParserHead, decode
from stanza_parser_head import StanzaParserHead
from repair_structures import tokenize

SENTENCES = [
    'I want to write to edit the code',
    'I want to write, no, to edit the code.',
    'I want to edit the code.',
    'I want to learn to drive.',
    'I need to work to pay the rent.',
    'I want to write in order to edit the code.',
    'the cat the dog is eating',
    'The cat that the dog is eating is hungry.',
    "Isn't removing a repeat a sort of substitution rule?",
    'The surface feels rather rough, no, I mean very smooth.',
    'Please open the red the blue file.',
    'Please open the red and the blue file.',
    'I know that that works.',
    'She can can peaches.',
    'I saw the man with a telescope.',
]

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def tree(words, parents, relations):
    lines = []
    def visit(parent, prefix):
        children = [i for i, h in enumerate(parents, 1) if h == parent]
        for k, i in enumerate(children):
            last = k == len(children)-1
            lines.append(prefix + ('└── ' if last else '├── ') + f'{words[i-1]} [{i}] ({relations[i-1]})')
            visit(i, prefix + ('    ' if last else '│   '))
    visit(0, '')
    assert len(lines) == len(words)
    return '\n'.join(lines)

@torch.inference_mode()
def main():
    torch.set_num_threads(4)
    out = Path('artifacts/lora-tree-probe-v1')
    out.mkdir(exist_ok=False)
    cfg = json.loads(Path('config.json').read_text())
    paths = {'compact_frozen': Path('artifacts/lora-syntax-only-v1/frozen-epoch2-weights.pt'),
             'compact_lora': Path('artifacts/lora-syntax-only-v1/lora-epoch2-weights.pt'),
             'large_epoch5': Path('artifacts/stanza-raw11-epochs5/epoch5.pt')}
    protocol = {'sentences': SENTENCES, 'device': 'cpu', 'checkpoints': {k: {'path':str(p), 'sha256':digest(p)} for k,p in paths.items()},
                'source_sha256':digest(__file__), 'note':'Qualitative authored probes, no gold trees or aggregate accuracy. Same regex word tokenization for all models; contractions unsplit. Large head has different training history.'}
    (out/'protocol.json').write_text(json.dumps(protocol, indent=2))
    tokenizer = AutoTokenizer.from_pretrained(cfg['model_id'], revision=cfg['model_revision'], local_files_only=True)
    lm = AutoModelForMaskedLM.from_pretrained(cfg['model_id'], revision=cfg['model_revision'], local_files_only=True, attn_implementation='eager').eval().requires_grad_(False)
    install_adapters(lm.model)
    checkpoints = {k:torch.load(p, map_location='cpu', weights_only=True) for k,p in paths.items()}
    load_adapter_state(lm.model, checkpoints['compact_lora']['adapters'])
    online = OnlineFeatures(tokenizer, lm, 'cpu')
    heads = {}
    for name, ckpt in checkpoints.items():
        cls = StanzaParserHead if name == 'large_epoch5' else ParserHead
        head = cls(**ckpt['settings']); head.load_state_dict(ckpt['head']); heads[name] = head.eval()
    rows = []
    for text in SENTENCES:
        words = tokenize(text)[0]
        predictions = {}
        for name, head in heads.items():
            set_adapters(lm.model, name == 'compact_lora')
            features = online([{'words':words}])
            mask = torch.ones(features.shape[:2], dtype=torch.bool)
            arcs, labels = head(features,mask)
            parents, rels = decode(arcs[0],labels[0],len(words),RELATIONS)
            predictions[name] = {'heads':parents,'labels':rels,'tree':tree(words,parents,rels)}
        rows.append({'text':text,'words':words,'predictions':predictions})
    (out/'results.json').write_text(json.dumps(rows, indent=2, ensure_ascii=False))
    report = ['# Sentence tree comparison', '', protocol['note'], '', 'Labels: xcomp = open clausal complement; advcl = adverbial clause; acl = noun-modifying clause; reparandum = abandoned material attached to its replacement. Token numbers distinguish repeated words.', '']
    for row in rows:
        report += ['## '+row['text'], '']
        for name, p in row['predictions'].items():
            report += ['### '+name, '', '```text', p['tree'], '```', '']
    Path('LORA_TREE_PROBES.md').write_text('\n'.join(report))
    print('Saved 15 sentences × 3 models to LORA_TREE_PROBES.md')

if __name__ == '__main__': main()
