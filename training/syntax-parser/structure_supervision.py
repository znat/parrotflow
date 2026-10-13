"""Local v1 repair supervision without inventing a complete dependency tree.

The boundary is deliberately stronger than the lexical evaluator: every outside
regex token, including punctuation, must avoid abandoned lexical parents. This
prevents punctuation-mediated paths into the abandoned subtree. It assigns no
positive head or label to outside tokens and does not supervise cue cleanup.
"""
import torch
from torch.nn import functional as F

from partial_supervision import partial_loss
from repair_structures import validate_record


def structure_loss(arcs, labels, rows, relations):
    """Mean per-example loss: mean edge CE + weight-1 mean boundary NLL.

    Arc layout is [batch, dependent, head], with index 0 for ROOT; labels
    have an additional relation dimension. Keep rows use partial_loss's lexical
    marginal reparandum suppression. Rows must be valid, eligible v1 records.
    Finite masked scores (e.g. -1e9) are supported; padding is never supervised.
    """
    if not rows:
        raise ValueError('Structure supervision requires a nonempty batch')
    if (arcs.ndim != 3 or labels.ndim != 4 or arcs.shape != labels.shape[:3]
            or arcs.shape[0] != len(rows) or labels.shape[-1] != len(relations)):
        raise ValueError('Incompatible structure supervision tensor shapes')
    if 'reparandum' not in relations:
        raise ValueError('Missing reparandum relation')
    losses = []
    for b, row in enumerate(rows):
        if (row.get('label') not in ('repair', 'keep') or row.get('quarantine_reason')
                or row.get('review_disposition') == 'quarantined'
                or row.get('protected_eval_overlap')):
            raise ValueError('Only eligible repair/keep records may train')
        issues = validate_record(row)
        if issues:
            raise ValueError('; '.join(issues))
        n = len(row['words'])
        if min(arcs.shape[1:]) < n + 1:
            raise ValueError('Tensor does not cover record tokens')
        if row['label'] == 'keep':
            losses.append(partial_loss(arcs[b:b+1], labels[b:b+1], [row], relations))
            continue
        edges = [row['repair_edge']] + row['internal_edges']
        edge_losses = []
        for edge in edges:
            dep, head = edge['dep'], edge['head']
            if edge['label'] not in relations:
                raise ValueError('Missing supervised relation: ' + edge['label'])
            edge_losses.append(
                F.cross_entropy(arcs[b, dep, :n+1].unsqueeze(0),
                                torch.tensor([head], device=arcs.device))
                + F.cross_entropy(labels[b, dep, head].unsqueeze(0),
                                  torch.tensor([relations.index(edge['label'])], device=labels.device)))
        abandoned = set(row['abandoned_token_ids'])
        outside = [i for i in range(1, n+1) if i not in abandoned]
        allowed = [i for i in range(n+1) if i not in abandoned]
        outside_scores = arcs[b, outside, :n+1]
        # Difference of log partitions avoids cancellation/clamping when the
        # probability of an abandoned parent is very close to one.
        boundary = (outside_scores.logsumexp(-1)
                    - outside_scores[:, allowed].logsumexp(-1)).mean()
        losses.append(torch.stack(edge_losses).mean() + boundary)
    return torch.stack(losses).mean()
