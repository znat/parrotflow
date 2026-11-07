"""Frozen mmBERT raw block-12 features and base-weight integrity."""
import hashlib
import torch
from campaign.adapters import prefix_states
from campaign.common import require

def base_hash(model):
    """Hash frozen model tensors, ignoring LoRA parameters and wrapper names."""
    h = hashlib.sha256()
    for name, value in model.state_dict().items():
        if name.endswith(('lora_A', 'lora_B')):
            continue
        h.update(name.replace('.base.', '.').encode())
        h.update(value.detach().cpu().contiguous().numpy().tobytes())
    return h.hexdigest()

def pooling_matrix(word_ids, counts, device):
    """Build mean-pooling weights and reject words without aligned subwords."""
    weights = torch.zeros(len(counts), max(counts), len(word_ids[0]))
    for i, count in enumerate(counts):
        for j, word in enumerate(word_ids[i]):
            if word is not None:
                weights[i, word, j] = 1
        assert torch.all(weights[i, :count].sum(-1) > 0)
    return (weights / weights.sum(-1, keepdim=True).clamp_min(1)).to(device)


class Layer12Features:
    """Mean-pool gold-word subwords from raw block 12 before final normalization."""
    def __init__(self, tokenizer, model, device):
        """Bind the tokenizer, frozen encoder and execution device."""
        self.tokenizer, self.model, self.device = tokenizer, model, device

    def inputs(self, rows):
        """Build checked token alignment and normalized word-pooling weights."""
        require(rows and all(r['words'] for r in rows), 'Empty encoder input')
        tokens=self.tokenizer([r['words'] for r in rows],is_split_into_words=True,
                              padding=True,truncation=False,return_tensors='pt')
        require(tokens['input_ids'].shape[1]<=256,'Never truncate trees')
        weights=pooling_matrix([tokens.word_ids(i) for i in range(len(rows))],
                               [len(r['words']) for r in rows],self.device)
        return tokens.to(self.device),weights

    def __call__(self, rows):
        """Return differentiable word features with the established FP16 roundtrip."""
        tokens,weights=self.inputs(rows)
        hidden=prefix_states(self.model.model,tokens['input_ids'],tokens['attention_mask'],blocks=12)
        return torch.bmm(weights,hidden).half().float()
