"""Small biaffine head; no encoder or MLM weights in parser checkpoints."""
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F
from stanza.models.common.chuliu_edmonds import chuliu_edmonds_one_root


class Biaffine(nn.Module):
    def __init__(self, dim, outputs):
        super().__init__()
        self.weight = nn.Parameter(torch.empty(outputs, dim + 1, dim + 1))
        nn.init.xavier_uniform_(self.weight)

    def forward(self, dependent, parent, aligned=False):
        dependent = F.pad(dependent, (0, 1), value=1)
        parent = F.pad(parent, (0, 1), value=1)
        if aligned:
            return torch.einsum("bxi,oij,bxj->bxo", dependent, self.weight, parent)
        return torch.einsum("bxi,oij,byj->bxyo", dependent, self.weight, parent)


class ParserHead(nn.Module):
    def __init__(self, hidden_size, relations, arc_dim=128, label_dim=64, dropout=0.2):
        super().__init__()
        self.settings = dict(hidden_size=hidden_size, relations=relations, arc_dim=arc_dim,
                             label_dim=label_dim, dropout=dropout)
        self.root = nn.Parameter(torch.zeros(hidden_size))
        def projection(dim):
            return nn.Sequential(nn.Linear(hidden_size, dim), nn.ELU(), nn.Dropout(dropout))
        self.arc_dep, self.arc_head = projection(arc_dim), projection(arc_dim)
        self.rel_dep, self.rel_head = projection(label_dim), projection(label_dim)
        self.arc = Biaffine(arc_dim, 1)
        self.rel = Biaffine(label_dim, len(relations))

    def forward(self, words, mask, gold_heads=None):
        x = torch.cat([self.root.expand(words.size(0), 1, -1), words], dim=1)
        arcs = self.arc(self.arc_dep(x), self.arc_head(x)).squeeze(-1)
        rel_dep, rel_head = self.rel_dep(x), self.rel_head(x)
        if gold_heads is None:
            labels = self.rel(rel_dep, rel_head)
        else:
            # Label loss supervises only gold edges. Avoid the quadratic label
            # tensor during training; this is the same score on those edges.
            parents = F.pad(gold_heads.clamp_min(0), (1, 0))
            selected = rel_head.gather(1, parents[..., None].expand(-1, -1, rel_head.size(-1)))
            labels = self.rel(rel_dep, selected, aligned=True)
        parent_mask = F.pad(mask, (1, 0), value=True)
        arcs = arcs.masked_fill(~parent_mask[:, None, :], float("-inf"))
        arcs = arcs.masked_fill(torch.eye(x.size(1), device=x.device, dtype=torch.bool)[None], float("-inf"))
        return arcs, labels


def loss_for(arcs, labels, heads, relations, mask):
    # Select actual dependents before CE: padded rows may be entirely masked.
    arc_loss = F.cross_entropy(arcs[:, 1:][mask], heads[mask])
    if labels.ndim == 3:
        selected = labels[:, 1:]
    else:
        selected = labels[:, 1:].gather(2, heads.clamp_min(0)[..., None, None].expand(-1, -1, 1, labels.size(-1))).squeeze(2)
    return arc_loss + F.cross_entropy(selected[mask], relations[mask])


def decode(arcs, labels, length, relation_names):
    scores = arcs[:length + 1, :length + 1].detach().cpu()
    # Stanza's one-root decoder expects log probabilities, not arbitrary positive logits.
    scores[0] = 0
    scores = F.log_softmax(scores, dim=-1).numpy().astype(np.float64)
    heads = chuliu_edmonds_one_root(scores)[1:].tolist()
    rel = labels.detach().cpu().clone()
    root_label = relation_names.index("root")
    result = []
    for dependent, head in enumerate(heads, 1):
        if head == 0:
            result.append("root")
        else:
            rel[dependent, head, root_label] = float("-inf")
            result.append(relation_names[int(rel[dependent, head].argmax())])
    return heads, result


def batch_rows(rows, device):
    lengths = [len(row["words"]) for row in rows]
    features = torch.zeros(len(rows), max(lengths), rows[0]["features"].size(-1))
    mask = torch.zeros(len(rows), max(lengths), dtype=torch.bool)
    heads = torch.full(mask.shape, -100, dtype=torch.long)
    relations = torch.full(mask.shape, -100, dtype=torch.long)
    names = rows[0]["relation_names"]
    for i, (row, length) in enumerate(zip(rows, lengths)):
        features[i, :length] = row["features"].float()
        mask[i, :length] = True
        heads[i, :length] = torch.tensor(row["heads"])
        relations[i, :length] = torch.tensor([names.index(r) for r in row["labels"]])
    return tuple(t.to(device) for t in (features, mask, heads, relations))
