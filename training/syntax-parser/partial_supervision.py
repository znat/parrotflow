"""Partial dependency supervision without inventing unannotated tree edges."""
import torch
from torch.nn import functional as F


def partial_loss(arcs, labels, rows, relations):
    repair_id = relations.index('reparandum')
    losses = []
    for b, row in enumerate(rows):
        n = len(row['words'])
        if row['label'] == 'repair':
            edges = [{'dep': row['dep_index'], 'head': row['head_index'], 'label': 'reparandum'}] + row.get('internal_edges', [])
            edge_losses = []
            for edge in edges:
                dep, head = edge['dep'], edge['head']
                if not (1 <= dep <= n and 1 <= head <= n and dep != head):
                    raise ValueError('Invalid partial dependency')
                edge_losses.append(F.cross_entropy(arcs[b, dep, :n+1].unsqueeze(0), torch.tensor([head], device=arcs.device)) +
                                   F.cross_entropy(labels[b, dep, head].unsqueeze(0), torch.tensor([relations.index(edge['label'])], device=labels.device)))
            losses.append(torch.stack(edge_losses).mean())
        elif row['label'] == 'keep':
            # Expected reparandum probability over possible parents. Root cannot
            # carry this label in the decoder; no positive syntactic labels assumed.
            parent_prob = arcs[b, 1:n+1, :n+1].softmax(-1)
            repair_prob = labels[b, 1:n+1, :n+1].softmax(-1)[..., repair_id]
            joint = (parent_prob[:, 1:] * repair_prob[:, 1:]).sum(-1)
            lexical = torch.tensor([any(c.isalnum() for c in w) for w in row['words']], device=arcs.device)
            if not lexical.any():
                raise ValueError('Keep example has no lexical words')
            losses.append(-torch.log1p(-joint[lexical].clamp(max=1-1e-6)).mean())
        else:
            raise ValueError('Only reviewed repair/keep proposals may train')
    return torch.stack(losses).mean()
