"""Surface alignment and conservative label-preserving views; no gold repair oracle."""
import copy
import re
from campaign.common import require, normalized


def aligned_units(row):
    text, words = row['text'], row['words']
    units = copy.deepcopy(row.get('surface_ud_map'))
    if units is None:
        mwts = {}
        for m in row.get('mwt', []):
            if 'id' not in m:
                continue
            a,b = map(int,m['id'].split('-'))
            mwts[a] = (b,m['form'])
        units=[]; i=1; cursor=0
        while i<=len(words):
            last, form = mwts.get(i,(i,words[i-1]))
            while cursor<len(text) and text[cursor].isspace(): cursor+=1
            require(text.startswith(form,cursor), 'Surface alignment unavailable')
            units.append(dict(surface=form,start=cursor,end=cursor+len(form),ud_token_ids=list(range(i,last+1))))
            cursor+=len(form);i=last+1
        require(not text[cursor:].strip(), 'Unaligned trailing source text')
    covered=[]; last=0
    for u in units:
        a,b=u['start'],u['end']; ids=u['ud_token_ids']
        require(0<=a<b<=len(text) and a>=last and not text[last:a].strip(), 'Invalid surface span')
        require(text[a:b]==u['surface'], 'Surface text mismatch')
        require(ids and ids==list(range(ids[0],ids[-1]+1)), 'Noncontiguous unit')
        covered.extend(ids);last=b
    require(covered==list(range(1,len(words)+1)) and not text[last:].strip(), 'Incomplete surface coverage')
    return units


def input_only(row):
    # Deliberate allowlist: no gold tree, intent, abandoned/latest/cue annotations.
    return dict(text=row['text'], words=row['words'], language=row['language'],
                surface_ud_map=aligned_units(row))


def view(row, mode, forbidden=()):
    """Training only. Punctuation reduction removes a terminal leaf period only.

    Do not derive new repair labels by dropping cue punctuation. Missing alignment
    or a non-invariant transform reverts to original and records the reason.
    """
    require(mode in ('original','lowercase','punctuation_reduced'), 'Unknown view')
    out=copy.deepcopy(row);out['augmentation']=mode
    if mode=='original': return out
    try:
        units=aligned_units(row)
        if mode=='lowercase':
            text=row['text']; boundary=[0]
            for ch in text:boundary.append(boundary[-1]+len(ch.lower()))
            out['text']=''.join(ch.lower() for ch in text)
            out['words']=[w.lower() for w in row['words']]
            for u in units:
                u['start'],u['end']=boundary[u['start']],boundary[u['end']]
                u['surface']=out['text'][u['start']:u['end']]
        else:
            n=len(row['words'])
            require(row['words'][-1]=='.' and row['labels'][-1]=='punct', 'No removable terminal period')
            require(n not in row['heads'] and len(units[-1]['ud_token_ids'])==1, 'Nonleaf or shared period')
            require(units[-1]['ud_token_ids']==[n], 'Invalid terminal unit')
            out['text']=row['text'][:units[-1]['start']].rstrip(); units.pop()
            for key in ('words','heads','labels','upos','morph','morph_observed'):
                if key in out:out[key]=out[key][:-1]
            require(all(h<n for h in out['heads']), 'Dangling head')
        out['surface_ud_map']=units
        # Training targets are trees only. Do not leave stale repair/offset metadata
        # on a transformed row; evaluation uses untouched originals.
        for key in list(out):
            if key in ('mwt','token_starts','token_ends','token_ids','intended_output','repair_edge','replacement_span','delete_spans','delete_token_ids') or key.startswith(('abandoned_','latest_','cue_')):
                del out[key]
        aligned_units(out)
        require(normalized(out['text']) not in forbidden, 'Augmentation collides with heldout')
        return out
    except (ValueError,KeyError,IndexError) as exc:
        result=copy.deepcopy(row)
        result.update(augmentation='original',augmentation_requested=mode,augmentation_rejected=str(exc))
        return result
