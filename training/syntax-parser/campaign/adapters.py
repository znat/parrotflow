"""Switchable attention LoRA and a tested raw ModernBERT prefix forward.

Base parameters are never merged or updated. Disable adapters for MLM use.
This module targets the project's pinned Transformers ModernBERT implementation.
"""
import math

import torch
from torch import nn
from transformers.masking_utils import create_bidirectional_mask, create_bidirectional_sliding_window_mask


class LoRALinear(nn.Module):
    def __init__(self, base, rank=4, alpha=8):
        """Wrap a frozen projection with zero-initialized rank-limited updates."""
        super().__init__()
        self.base = base.requires_grad_(False)
        self.lora_A = nn.Parameter(torch.empty(rank, base.in_features, device=base.weight.device, dtype=base.weight.dtype))
        self.lora_B = nn.Parameter(torch.zeros(base.out_features, rank, device=base.weight.device, dtype=base.weight.dtype))
        nn.init.kaiming_uniform_(self.lora_A, a=math.sqrt(5))
        self.scale = alpha / rank
        self.enabled = True

    def forward(self, x):
        """Apply the frozen projection and, when enabled, its LoRA update."""
        original = self.base(x)
        if not self.enabled:
            return original
        return original + ((x @ self.lora_A.T) @ self.lora_B.T) * self.scale


def install_adapters(encoder, blocks=12, rank=4, alpha=8):
    """Install trainable attention LoRA in the selected frozen prefix."""
    if not 0 < blocks <= len(encoder.layers):
        raise ValueError('Invalid prefix length')
    encoder.requires_grad_(False)
    for layer in encoder.layers[:blocks]:
        for name in ('Wqkv', 'Wo'):
            base = getattr(layer.attn, name)
            if not isinstance(base, nn.Linear):
                raise TypeError('Expected an unmodified attention projection')
            setattr(layer.attn, name, LoRALinear(base, rank, alpha))


def set_adapters(encoder, enabled):
    """Enable or disable all installed updates without merging base weights."""
    for module in encoder.modules():
        if isinstance(module, LoRALinear):
            module.enabled = enabled


def adapter_state(encoder):
    """Return independent CPU copies of adapter parameters."""
    return {name: value.detach().cpu().clone() for name, value in encoder.named_parameters()
            if name.endswith(('lora_A', 'lora_B'))}


def load_adapter_state(encoder, state):
    """Validate adapter keys and shapes before copying saved parameters."""
    expected = adapter_state(encoder)
    if expected.keys() != state.keys():
        raise ValueError('Adapter key mismatch')
    with torch.no_grad():
        for name, value in encoder.named_parameters():
            if name in state:
                if value.shape != state[name].shape:
                    raise ValueError('Adapter shape mismatch')
                value.copy_(state[name])


def prefix_states(encoder, input_ids, attention_mask, blocks=12):
    """Match raw output of block N without evaluating later blocks/final norm."""
    hidden = encoder.embeddings(input_ids=input_ids)
    mask_args = {'config': encoder.config, 'inputs_embeds': hidden, 'attention_mask': attention_mask}
    masks = {'full_attention': create_bidirectional_mask(**mask_args),
             'sliding_attention': create_bidirectional_sliding_window_mask(**mask_args)}
    positions = torch.arange(input_ids.shape[1], device=input_ids.device).unsqueeze(0)
    rotary = {kind: encoder.rotary_emb(hidden, positions, kind) for kind in set(encoder.config.layer_types)}
    for layer in encoder.layers[:blocks]:
        hidden = layer(hidden, attention_mask=masks[layer.attention_type], position_embeddings=rotary[layer.attention_type])
    return hidden
