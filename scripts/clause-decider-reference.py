#!/usr/bin/env python3
"""Write tests/clause-decider-parity.json: what the PyTorch clause decider answers.

    python scripts/clause-decider-reference.py --reference <syntax-parser dir> [--out FILE] [--batch FILE]

<syntax-parser dir> holds the training code the decider was fitted with
(vocab_clause_core, vocab_clause_syrinx, vocab_gate_v2_data) and the t-silver
42 checkpoint. Run it with that directory's venv; espeak-ng must be installed.
The weights are read from built-in/data/vocab-clause.safetensors, the file the
app bundles. `--batch` reads items in the same shape instead of the built-in
cases, for a local run on text that may not be committed.

An item: the text with the heard words in place, their scalar offsets a..b,
the heard words, the term, and the term's stored rows (TermUses: said, span,
counter, heard). Every case below was written for this repository.
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WEIGHTS = ROOT / "built-in/data/vocab-clause.safetensors"
# A case this close to a decision bound can flip on float noise alone, so it is
# left out rather than compared.
MARGIN = 1e-3


def use(said, span, counter=False, heard=None):
    return dict(said=said, span=span, counter=counter, heard=heard)


VERCEL = [
    use("We deploy the web app on Vercel every Friday.", "Vercel", heard="Versal"),
    use("The Vercel preview build failed again this morning.", "Vercel"),
    use("I moved the API routes to Vercel last week.", "Vercel"),
    use("We visited the palace of Versailles during the summer holidays.", "Versailles", counter=True),
]
MIRZA = [
    use("Mirza reviewed the pull request before lunch.", "Mirza"),
    use("I asked Mirza about the release notes.", "Mirza", heard="Mirsa"),
    use("Mira is my neighbour's daughter and she plays the violin.", "Mira", counter=True),
]
SUPABASE = [
    use("We store the user table in Supabase.", "Supabase", heard="super base"),
    use("The Supabase project has row level security turned on.", "Supabase"),
]
REDCRAWL = [
    use("Redcrawl indexes the Slack threads every night.", "Redcrawl"),
    use("We shipped Redcrawl to production on Tuesday.", "Redcrawl"),
]
REDROCK = [
    use("Redrock handles the PII redaction chain.", "Redrock"),
    use("The Redrock roadmap is due next month.", "Redrock"),
    use("The trail runs along a red rock ridge above the canyon.", "red rock", counter=True),
]
LONG = " ".join(
    ["We talked about the staging server, the flaky tests, the build cache and the release notes for a while."] * 9
    + ["Then I deployed the app to Versal and went home."]
)
CASES = [
    ("vercel-versal", "I deploy my app on Versal but I love visiting the Versailles castle.", "Versal", "Vercel", VERCEL),
    ("vercel-versailles", "I deploy my app on Versal but I love visiting the Versailles castle.", "Versailles", "Vercel",
     VERCEL),
    ("vercel-question", "Did you push the fix to Versal?!", "Versal", "Vercel", VERCEL),
    ("vercel-alone", "Versal.", "Versal", "Vercel", VERCEL),
    ("vercel-long", LONG, "Versal", "Vercel", VERCEL),
    ("mirza-mira", "So Mirza and Mira are going to the movies.", "Mira", "Mirza", MIRZA),
    ("mirza-murza", "Murza set up the database migration yesterday.", "Murza", "Mirza", MIRZA),
    ("ghostty-cold", "I opened three tabs in Ghost T before the demo.", "Ghost T", "Ghostty", []),
    ("ghostty-cold-word", "The old house felt ghostly after midnight.", "ghostly", "Ghostty", []),
    ("supabase-pair", "The super base key expired yesterday.", "super base", "Supabase", SUPABASE),
    ("supabase-bass", "He plays a super bass line in the second song.", "super bass", "Supabase", SUPABASE),
    ("two-crawl", "Red Crawl indexes the threads overnight, but Red Rock still handles the chain.", "Red Crawl",
     "Redcrawl", REDCRAWL),
    ("two-rock", "Red Crawl indexes the threads overnight, but Red Rock still handles the chain.", "Red Rock",
     "Redrock", REDROCK),
    ("rock-ridge", "We hiked to the red rock ridge at sunrise.", "red rock", "Redrock", REDROCK),
    ("unfound-row", "I pushed the branch to Versal this morning.", "Versal", "Vercel",
     [use("I liked Vercelli a lot.", "Vercel"), use("The Vercel dashboard shows the logs.", "Vercel")]),
]


def items(args):
    if args.batch:
        return json.loads(Path(args.batch).read_text())
    out = []
    for key, text, heard, term, rows in CASES:
        a = text.index(heard)
        out.append(dict(id=key, text=text, a=a, b=a + len(heard), heard=heard, term=term, uses=rows))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--reference", type=Path, required=True)
    ap.add_argument("--out", type=Path, default=ROOT / "tests" / "clause-decider-parity.json")
    ap.add_argument("--batch", type=Path)
    args = ap.parse_args()
    todo = items(args)
    args.reference, args.out = args.reference.resolve(), args.out.resolve()
    os.chdir(args.reference)
    sys.path.insert(0, str(args.reference))
    sys.dont_write_bytecode = True
    from safetensors.numpy import load_file
    from safetensors import safe_open

    import vocab_clause_core as C
    import vocab_gate_v2_data as V2
    from vocab_clause_syrinx import Syrinx

    t = load_file(str(WEIGHTS))
    with safe_open(str(WEIGHTS), "np") as fh:
        meta = fh.metadata()
    names = json.loads(meta["features"])
    model = dict(names=names, w=t["w"].astype(float).tolist(), mu=t["mu"].astype(float).tolist(),
                 sd=t["sd"].astype(float).tolist(), bias=float(t["bias"][0]),
                 absent=dict(zip(json.loads(meta["absent"]), t["absent"].astype(float).tolist())),
                 fixed=dict(zip(json.loads(meta["fixed"]), t["fixed"].astype(float).tolist())))
    write, leave = float(meta["write"]), float(meta["leave"])
    assert C.WRITE == write and C.LEAVE == leave and C.MIN_POOL == int(meta["min_pool"])
    centre, proj, ner = t["centre"], t["proj"], (t["ner.weight"], t["ner.bias"])
    ipa = V2.IPA("en-us")
    dictionary = {w.strip().lower() for w in Path("/usr/share/dict/words").read_text().split("\n")}

    def known(heard):
        def one(w):
            w = w.lower()
            return w in dictionary or (w.endswith("s") and w[:-1] in dictionary) or (
                w.endswith("es") and w[:-2] in dictionary)
        runs = re.findall(r"[^\W\d_]+", heard)
        return float(bool(runs) and all(one(w) for w in runs))

    def place(p, a, b):
        span = C.span_tokens(p, a, b)
        if not span:
            return None, span, []
        toks = C.pool_tokens(p, span)
        return C.vector(p, toks, centre, proj), span, toks

    syrinx = Syrinx()
    parses = syrinx.analyse([it["text"] for it in todo] + [u["said"] for it in todo for u in it["uses"]])
    sounds = ipa.of([x for it in todo for x in (it["heard"], it["term"])])
    lines, close = [], []
    for it in todo:
        p = parses[it["text"]]
        acc, ref = [], []
        for u in it["uses"]:
            at = C.occurrence(u["span"], u["said"])
            v = place(parses[u["said"]], *at)[0] if at else None
            if v is not None:
                (ref if u["counter"] else acc).append(v)
        acc_forms = {C.norm(u["heard"]) for u in it["uses"] if not u["counter"] and u.get("heard")}
        ref_forms = {C.norm(u["span"]) for u in it["uses"] if u["counter"]}
        v, span, toks = place(p, it["a"], it["b"])
        if not span:
            lines.append(dict(id=it["id"], declined="no parser token at the place"))
            continue
        ca, cr = C.centroid(acc), C.centroid(ref)
        f = {"sim_acc": float(v @ ca) if v is not None and ca is not None else None,
             "sim_ref": float(v @ cr) if v is not None and cr is not None else None,
             "ner": C.ner_entity(ner, p, span), **C.pos_features(p, span),
             "sound": V2.similarity(sounds[it["heard"]], sounds[it["term"]]), "known": known(it["heard"]),
             "pair_acc": float(C.norm(it["heard"]) in acc_forms), "pair_ref": float(C.norm(it["heard"]) in ref_forms)}
        d, prob, z, _ = C.decide(model, f)
        clause = [min(p["starts"][k] for k in toks), max(p["ends"][k] for k in toks)] if toks else None
        line = dict(id=it["id"], decision=d, p=round(prob, 6), z=round(z, 6), clause=clause,
                    features={k: (round(x, 6) if x is not None else None) for k, x in f.items()})
        if not args.batch:
            line.update(text=it["text"], a=it["a"], b=it["b"], heard=it["heard"], term=it["term"], uses=it["uses"])
        if min(abs(prob - write), abs(prob - leave)) < MARGIN:
            close.append(it["id"])
            continue
        lines.append(line)
    args.out.write_text("[\n" + ",\n".join(json.dumps(x, ensure_ascii=False, separators=(",", ":")) for x in lines)
                        + "\n]\n")
    print(f"{len(lines)} items -> {args.out}; left out near a bound: {close}")


if __name__ == "__main__":
    main()
