#!/usr/bin/env python3
"""Build parrot-syrinx for the app: the encoder as Core ML, the rest as safetensors.

Toolchain, pinned. Other versions were not checked for parity:
    python 3.13, torch==2.7.0, coremltools==9.0, numpy==2.2.6, safetensors==0.8.0

    python scripts/convert-syrinx-coreml.py --weights <export dir> --tokenizer <tokenizer.json> --out <dir>

<export dir> holds base.safetensors, grammar.safetensors, syntax.safetensors and
manifest.json. <out> receives the three files the app downloads:

    parrot-syrinx.mlpackage  12 mmBERT-small blocks run twice, once per LoRA path
                             (merged), on embeddings passed in. Outputs g_hidden
                             and s_hidden, block 12 before final_norm.
    syrinx.safetensors       the 256000 x 384 embedding table, the grammar heads,
                             the fusion and the biaffine parser, in float32. The
                             label names are in its metadata.
    tokenizer.json           copied unchanged.
"""
import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path

import numpy as np
import torch
from safetensors.torch import load_file, save_file
from torch.nn import functional as F

LENGTH = 256
# -inf would give a padded query row with no real key in its window a NaN.
NEG = -1e4


class Encoder(torch.nn.Module):
    def __init__(self, manifest, base, loras):
        super().__init__()
        enc = manifest['encoder']
        self.blocks, self.heads, self.head_dim = enc['blocks_run'], enc['heads'], enc['head_dim']
        self.full = set(enc['full_attention_blocks'])
        theta = set(enc['rope']['theta'].values())
        assert len(theta) == 1, 'one RoPE theta for both layer types'
        scaling = manifest['lora']['scaling']
        self.p = torch.nn.ParameterDict()

        def keep(name, tensor):
            self.p[name.replace('.', '_')] = torch.nn.Parameter(tensor.contiguous(), requires_grad=False)

        keep('emb_norm', base['embeddings.norm.weight'])
        for k, v in base.items():
            if k.startswith('layers.'):
                keep(k, v)
        for path, lora in loras.items():
            for i in range(self.blocks):
                for module in ('attn.Wqkv', 'attn.Wo'):
                    name = f'layers.{i}.{module}'
                    delta = lora[f'lora.{name}.lora_B'] @ lora[f'lora.{name}.lora_A']
                    keep(f'{path}.{name}.weight', base[name + '.weight'] + scaling * delta)
        inv = 1.0 / (theta.pop() ** (torch.arange(0, self.head_dim, 2, dtype=torch.float) / self.head_dim))
        freqs = torch.arange(LENGTH).float()[:, None] * inv
        both = torch.cat((freqs, freqs), dim=-1)
        self.register_buffer('cos', both.cos())
        self.register_buffer('sin', both.sin())
        pos = torch.arange(LENGTH)
        far = (pos[:, None] - pos[None, :]).abs() > enc['sliding_window']['half_window']
        self.register_buffer('window', torch.zeros(LENGTH, LENGTH).masked_fill(far, NEG))

    def rotate(self, v):
        half = v.shape[-1] // 2
        return v * self.cos + torch.cat((-v[..., half:], v[..., :half]), dim=-1) * self.sin

    def encode(self, x, keymask, path):
        p = self.p
        for i in range(self.blocks):
            at = f'layers_{i}'
            h = x if i == 0 else F.layer_norm(x, (384,), p[at + '_attn_norm_weight'], None, 1e-5)
            qkv = (h @ p[f'{path}_{at}_attn_Wqkv_weight'].T).view(LENGTH, 3, self.heads, self.head_dim)
            q, k, v = (qkv[:, j].transpose(0, 1) for j in range(3))
            q, k = self.rotate(q), self.rotate(k)
            scores = (q @ k.transpose(1, 2)) * self.head_dim ** -0.5 + keymask
            if i not in self.full:
                scores = scores + self.window
            out = (scores.softmax(-1) @ v).transpose(0, 1).reshape(LENGTH, -1)
            x = x + out @ p[f'{path}_{at}_attn_Wo_weight'].T
            m = F.layer_norm(x, (384,), p[at + '_mlp_norm_weight'], None, 1e-5)
            a, g = (m @ p[at + '_mlp_Wi_weight'].T).chunk(2, dim=-1)
            x = x + (F.gelu(a) * g) @ p[at + '_mlp_Wo_weight'].T
        return x

    def forward(self, embeddings, attention_mask):
        x = F.layer_norm(embeddings[0], (384,), self.p['emb_norm'], None, 1e-5)
        keymask = ((1.0 - attention_mask.float()) * NEG)[0][None, None, :]
        return self.encode(x, keymask, 'g')[None], self.encode(x, keymask, 's')[None]


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--weights', type=Path, required=True)
    ap.add_argument('--tokenizer', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()

    import coremltools as ct
    import safetensors
    versions = dict(python='.'.join(map(str, sys.version_info[:2])), torch=torch.__version__,
                    coremltools=ct.__version__, numpy=np.__version__, safetensors=safetensors.__version__)
    wanted = dict(python='3.13', torch='2.7.0', coremltools='9.0', numpy='2.2.6', safetensors='0.8.0')
    if versions != wanted:
        raise SystemExit(f'pinned toolchain {wanted}, found {versions}')

    manifest = json.loads((args.weights / 'manifest.json').read_text())
    for name, entry in manifest['files'].items():
        if sha256(args.weights / name) != entry['sha256']:
            raise SystemExit(f'{name}: sha256 differs from manifest.json')
    base = load_file(str(args.weights / 'base.safetensors'))
    grammar = load_file(str(args.weights / 'grammar.safetensors'))
    syntax = load_file(str(args.weights / 'syntax.safetensors'))

    model = Encoder(manifest, base, {'g': grammar, 's': syntax}).eval()
    example = (torch.zeros((1, LENGTH, 384)), torch.ones((1, LENGTH), dtype=torch.int32))
    with torch.no_grad():
        traced = torch.jit.trace(model, example, strict=False)
    # FLOAT32 compute: FLOAT16 changed 27 of 3211 fixture trees and 18 of 60
    # long ones. An fp16 embedding table alone still changed 4 of 3372.
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name='embeddings', shape=(1, LENGTH, 384), dtype=np.float32),
                ct.TensorType(name='attention_mask', shape=(1, LENGTH), dtype=np.int32)],
        outputs=[ct.TensorType(name='g_hidden', dtype=np.float32), ct.TensorType(name='s_hidden', dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT32,
    )
    ml.short_description = 'parrot-syrinx encoder: mmBERT-small blocks 1-12, grammar and syntax LoRA merged'
    ml.license = 'Weights trained on Universal Dependencies treebanks (mostly CC BY-SA 4.0); base jhu-clsp/mmBERT-small (MIT)'
    ml.version = manifest['sources']['implementation_hash'][:12]

    args.out.mkdir(parents=True, exist_ok=True)
    package = args.out / 'parrot-syrinx.mlpackage'
    shutil.rmtree(package, ignore_errors=True)
    ml.save(str(package))

    heads = {k: v for k, v in grammar.items() if k.startswith('head.')}
    heads |= {k: v for k, v in syntax.items() if not k.startswith('lora.')}
    heads['embeddings'] = base['embeddings.tok_embeddings.weight']
    metadata = dict(
        inventories=json.dumps(manifest['inventories']['layout']),
        relations=json.dumps(manifest['passes']['relations']),
        max_subwords=str(manifest['tokenizer']['max_subwords']),
        source=manifest['sources']['implementation_hash'],
    )
    save_file({k: v.contiguous() for k, v in heads.items()}, str(args.out / 'syrinx.safetensors'), metadata=metadata)
    shutil.copyfile(args.tokenizer, args.out / 'tokenizer.json')
    print(json.dumps(versions | {'out': str(args.out)}))


if __name__ == '__main__':
    main()
