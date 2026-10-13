"""Pure deterministic proportional interleaving for the matched English pilot."""
from fractions import Fraction
import random


def epoch_orders(ud_count, local_count, epoch, seed=4211):
    """UD permutation depends only on UD count/epoch, never local arm size."""
    ud=list(range(ud_count));local=list(range(local_count))
    random.Random(seed+epoch).shuffle(ud)
    random.Random(seed+10000+epoch).shuffle(local)
    return ud,local


def interleaved_batches(ud_order, local_order, batch_size=16):
    """Merge batch midpoints on a common epoch timeline; visit each row once.

    Each stream preserves its supplied permutation. Integer Fraction ordering
    prevents rounding-dependent ties. At equal midpoint UD runs first. Batches
    remain loss-homogeneous; no repeated or balanced sampling is introduced.
    """
    if batch_size<1:raise ValueError('batch_size must be positive')
    for order in (ud_order,local_order):
        if len(order)!=len(set(order)):raise ValueError('duplicate row in stream')
    events=[]
    for priority,(name,order) in enumerate((('ud',ud_order),('local',local_order))):
        batches=[list(order[i:i+batch_size]) for i in range(0,len(order),batch_size)]
        for i,batch in enumerate(batches):
            events.append((Fraction(2*i+1,2*len(batches)),priority,name,batch))
    return [(name,batch) for _,_,name,batch in sorted(events,key=lambda event:event[:2])]
