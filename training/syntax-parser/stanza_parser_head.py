"""Stanza's graph parser core over raw frozen mmBERT word representations.

Uses installed HighwayLSTM and DeepBiaffineScorer, without Stanza embeddings,
char-LMs, tag inputs, arc embeddings or checkpoint weights. ROOT and recurrent
initial states are learned. Auxiliary objectives apply only to gold UD edges.
"""
import torch
from torch import nn
from torch.nn import functional as F
from torch.nn.utils.rnn import PackedSequence, pack_padded_sequence, pad_packed_sequence
from stanza.models.common.hlstm import HighwayLSTM
from stanza.models.common.biaffine import DeepBiaffineScorer
from stanza.models.common.dropout import WordDropout


class StanzaParserHead(nn.Module):
    def __init__(self, hidden_size, relations, hidden_dim=400, num_layers=3,
                 deep_biaff_hidden_dim=400, dropout=0.5, linearization=True, distance=True,
                 word_dropout=0.33):
        super().__init__()
        self.settings = dict(hidden_size=hidden_size, relations=list(relations),
            hidden_dim=hidden_dim, num_layers=num_layers,
            deep_biaff_hidden_dim=deep_biaff_hidden_dim, dropout=dropout,
            linearization=linearization, distance=distance, word_dropout=word_dropout)
        self.root = nn.Parameter(torch.zeros(hidden_size))
        self.parserlstm = HighwayLSTM(hidden_size, hidden_dim, num_layers,
            batch_first=True, bidirectional=True, dropout=dropout,
            rec_dropout=0, highway_func=torch.tanh)
        self.parserlstm_h_init = nn.Parameter(torch.zeros(2*num_layers, 1, hidden_dim))
        self.parserlstm_c_init = nn.Parameter(torch.zeros(2*num_layers, 1, hidden_dim))
        self.drop = nn.Dropout(dropout)
        self.worddrop = WordDropout(word_dropout)
        self.drop_replacement = nn.Parameter(torch.randn(hidden_size) / hidden_size**0.5)
        def scorer(outputs):
            return DeepBiaffineScorer(2*hidden_dim, 2*hidden_dim,
                deep_biaff_hidden_dim, outputs, pairwise=True, dropout=dropout)
        self.unlabeled = scorer(1)
        self.deprel = scorer(len(relations))
        self.linearization = scorer(1) if linearization else None
        self.distance = scorer(1) if distance else None
        self._aux = None

    @staticmethod
    def _validate(words, mask):
        if words.ndim != 3 or mask.shape != words.shape[:2] or mask.dtype != torch.bool:
            raise ValueError('Expected words [batch, words, hidden] and boolean word mask')
        lengths = mask.sum(1)
        expected = torch.arange(mask.shape[1], device=mask.device)[None] < lengths[:, None]
        if len(words) == 0 or (lengths == 0).any() or not torch.equal(mask, expected):
            raise ValueError('Expected nonempty sentences with contiguous right padding')
        return lengths

    @staticmethod
    def _gold_indices(gold_heads, mask):
        if gold_heads.shape != mask.shape or gold_heads.dtype != torch.long:
            raise ValueError('Expected integer gold heads matching word mask')
        lengths = mask.sum(1)
        if ((gold_heads < 0) & mask).any() or ((gold_heads > lengths[:, None]) & mask).any():
            raise ValueError('Gold head outside its sentence')
        return gold_heads.masked_fill(~mask, 0)

    def _encode(self, words, mask):
        lengths = self._validate(words, mask)
        inputs = torch.cat([self.root.expand(words.shape[0], 1, -1), words], 1)
        lengths_cpu = (lengths + 1).cpu()
        sorted_lengths, order = lengths_cpu.sort(descending=True)
        order = order.to(words.device)
        inverse = order.argsort()
        packed = pack_padded_sequence(inputs[order], sorted_lengths,
                                      batch_first=True, enforce_sorted=True)
        packed = PackedSequence(self.drop(self.worddrop(packed.data, self.drop_replacement)), packed.batch_sizes)
        batch_size = words.shape[0]
        shape = (2*self.settings['num_layers'], batch_size, self.settings['hidden_dim'])
        hx = (self.parserlstm_h_init.expand(shape).contiguous(),
              self.parserlstm_c_init.expand(shape).contiguous())
        outputs, _ = self.parserlstm(packed, sorted_lengths, hx=hx)
        outputs, _ = pad_packed_sequence(outputs, batch_first=True, total_length=inputs.shape[1])
        return outputs[inverse]

    def _selected_labels(self, dependent, parent, indices):
        """Exact selected-pair form of Stanza's pairwise biaffine contraction."""
        scorer = self.deprel
        dep = scorer.dropout(scorer.hidden_func(scorer.W1(dependent)))
        head = scorer.dropout(scorer.hidden_func(scorer.W2(parent)))
        head = head.gather(1, indices[..., None].expand(-1, -1, head.shape[-1]))
        dep, head = F.pad(dep, (0, 1), value=1), F.pad(head, (0, 1), value=1)
        bilinear = scorer.scorer.W_bilin
        return torch.einsum('bxi,ijo,bxj->bxo', dep, bilinear.weight, head) + bilinear.bias

    def forward(self, words, mask, gold_heads=None):
        outputs = self._encode(words, mask)
        arcs = self.unlabeled(self.drop(outputs), self.drop(outputs)).squeeze(-1)
        if gold_heads is None:
            labels = self.deprel(self.drop(outputs), self.drop(outputs))
        else:
            indices = F.pad(self._gold_indices(gold_heads, mask), (1, 0))
            labels = self._selected_labels(self.drop(outputs), self.drop(outputs), indices)
        positions = torch.arange(outputs.shape[1], device=outputs.device)
        offsets = positions[None, :] - positions[:, None]
        lin, dist_kld = None, None
        if self.linearization is not None:
            lin = self.linearization(self.drop(outputs), self.drop(outputs)).squeeze(-1)
            arcs = arcs + F.logsigmoid(lin * offsets.sign()).detach()
        if self.distance is not None:
            distance_scores = self.distance(self.drop(outputs), self.drop(outputs)).squeeze(-1)
            predicted = 1 + F.softplus(distance_scores)
            dist_kld = -torch.log((offsets.abs() - predicted).square()/2 + 1)
            arcs = arcs + dist_kld.detach()
        self._aux = (lin, dist_kld, offsets, mask)
        parents = F.pad(mask, (1, 0), value=True)
        arcs = arcs.masked_fill(~parents[:, None], float('-inf'))
        arcs = arcs.masked_fill(torch.eye(outputs.shape[1], device=outputs.device,
                                        dtype=torch.bool)[None], float('-inf'))
        return arcs, labels

    def auxiliary_loss(self, gold_heads, mask):
        """Mean Stanza direction CE + distance objective on real gold UD edges.

        Call immediately after the same batch's forward. Do not call for weak
        local supervision: those records do not provide complete gold heads.
        Detached arc biases leave these auxiliary scorers unaffected by arc CE.
        """
        if self._aux is None or not torch.equal(self._aux[3], mask):
            raise ValueError('Auxiliary loss requires the same batch mask as forward')
        heads = self._gold_indices(gold_heads, mask)
        lin, dist_kld, offsets, _ = self._aux
        result = self.root.sum() * 0
        if lin is not None:
            scores = lin[:, 1:].gather(2, heads[..., None]).squeeze(-1)[mask]
            targets = offsets[None, 1:].expand(len(mask), -1, -1).gather(
                2, heads[..., None]).squeeze(-1)[mask].gt(0).long()
            result = result + F.cross_entropy(torch.stack([-scores/2, scores/2], -1), targets)
        if dist_kld is not None:
            result = result - dist_kld[:, 1:].gather(2, heads[..., None]).squeeze(-1)[mask].mean()
        return result
