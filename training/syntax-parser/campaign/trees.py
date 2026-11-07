"""UD target tensors and strict single-root validation for the final pipeline."""
RELATIONS = sorted("acl advcl advmod amod appos aux case cc ccomp clf compound conj cop csubj dep det discourse dislocated expl fixed flat goeswith iobj list mark nmod nsubj nummod obj obl orphan parataxis punct reparandum root vocative xcomp".split())


def valid_tree(heads, labels=None):
    """Reject empty, out-of-range, cyclic or multi-root trees and inconsistent labels."""
    n=len(heads)
    if not n or any(type(h) is not int or not 0<=h<=n for h in heads) or heads.count(0)!=1:
        return False
    if labels is not None and (len(labels)!=n or any(r not in RELATIONS or (h==0)!=(r=='root') for h,r in zip(heads,labels))):
        return False
    for word in range(1,n+1):
        seen=set()
        while word:
            if word in seen:return False
            seen.add(word);word=heads[word-1]
    return True

def descendants(root, heads):
    """Collect a node and all transitively attached dependents."""
    found = {root}
    while True:
        extra = {i for i, h in enumerate(heads, 1) if h in found} - found
        if not extra:
            return found
        found.update(extra)

def ud_targets(rows, width, relation_names):
    """Exactly batch_rows target tensors without allocating unused frozen features."""
    import torch
    mask=torch.zeros(len(rows),width,dtype=torch.bool)
    parents=torch.full(mask.shape,-100,dtype=torch.long)
    relations=torch.full(mask.shape,-100,dtype=torch.long)
    for i,row in enumerate(rows):
        n=len(row['words'])
        assert n<=width
        mask[i,:n]=True
        parents[i,:n]=torch.tensor(row['heads'])
        relations[i,:n]=torch.tensor([relation_names.index(label) for label in row['labels']])
    return mask,parents,relations
