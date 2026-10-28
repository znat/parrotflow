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


def use(said, span, counter=False, heard=None, source="correction"):
    return dict(said=said, span=span, counter=counter, heard=heard, **{"from": source})


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
MIK = [
    use("Mik reviewed the pull request before the release.", "Mik"),
    use("I asked Mik to fix the failing build.", "Mik"),
    use("Mik pushed a patch for the login bug yesterday.", "Mik"),
]
MICK = [
    use("Mick played the guitar at the wedding.", "Mick"),
    use("We went to see Mick play a concert downtown.", "Mick"),
    use("Mick is practising the drums for the gig on Friday.", "Mick"),
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


# Two names in one sentence, one per clause: (key, text, which occurrence of the heard word, members' rows).
PIANO = "While Mick is playing the piano, Mick is reviewing pull requests."
DEPLOY = "Mick fixed the deploy script, and Mick sang two songs at the bar."
GROUPS = [
    ("group-piano-1", PIANO, 0, {"Mick": MICK, "Mik": MIK}),
    ("group-piano-2", PIANO, 1, {"Mick": MICK, "Mik": MIK}),
    ("group-deploy-1", DEPLOY, 0, {"Mick": MICK, "Mik": MIK}),
    ("group-deploy-2", DEPLOY, 1, {"Mick": MICK, "Mik": MIK}),
    ("group-cold", "Mick is reviewing pull requests today.", 0, {"Mick": MICK, "Mik": []}),
    # Heard "Mick" was once corrected to Mik, and Mick was once picked on the pill over Mik.
    ("group-history-1", "Mick is writing code while Mick is playing the piano.", 0, {
        "Mick": MICK + [use("Mick tuned the old piano before the show.", "Mick", source="chosen")],
        "Mik": MIK + [use("Mik merged the branch after the review.", "Mik", heard="Mick"),
                      use("Mick tuned the old piano before the show.", "Mick", counter=True, source="chosen")]}),
    ("group-history-2", "Mick is writing code while Mick is playing the piano.", 1, {
        "Mick": MICK + [use("Mick tuned the old piano before the show.", "Mick", source="chosen")],
        "Mik": MIK + [use("Mik merged the branch after the review.", "Mik", heard="Mick"),
                      use("Mick tuned the old piano before the show.", "Mick", counter=True, source="chosen")]}),
    # The same history without the refusal the choice now writes: both sides earn +1, so neither gets an edge.
    ("group-history-old", "Mick is writing code while Mick is playing the piano.", 1, {
        "Mick": MICK + [use("Mick tuned the old piano before the show.", "Mick", source="chosen")],
        "Mik": MIK + [use("Mik merged the branch after the review.", "Mik", heard="Mick")]}),
]
# A closed-class edge word dropped before reading: (key, text, heard, term, rows).
TRIMS = [
    ("trim-on", "Mik is deploying the app on Versal this afternoon.", "on Versal", "Vercel", VERCEL),
    ("trim-the", "We pushed the Versal build tonight.", "the Versal", "Vercel", VERCEL),
    ("trim-at", "I sent the notes to Matthew at work.", "Matthew at", "Matthieu", []),
    ("trim-none", "Red Rock still handles the redaction chain.", "Red Rock", "Redrock", REDROCK),
]
FLOOR = 0.60


def items(args):
    if args.batch:
        return json.loads(Path(args.batch).read_text())
    out = []
    for key, text, heard, term, rows in CASES:
        a = text.index(heard)
        out.append(dict(id=key, text=text, a=a, b=a + len(heard), heard=heard, term=term, uses=rows))
    for key, text, nth, members in GROUPS:
        a = [m.start() for m in re.finditer(r"\bMick\b", text)][nth]
        out.append(dict(id=key, text=text, a=a, b=a + 4, heard="Mick", term="Mick", uses=[], memory=members))
    for key, text, heard, term, rows in TRIMS:
        a = text.index(heard)
        out.append(dict(id=key, text=text, a=a, b=a + len(heard), heard=heard, term=term, uses=rows, trim=True,
                        floor=FLOOR))
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
    rows_of = lambda it: [u for rows in (it.get("memory") or {}).values() for u in rows] + it["uses"]
    parses = syrinx.analyse([it["text"] for it in todo] + [u["said"] for it in todo for u in rows_of(it)])

    def sound(heard, term):
        m = ipa.of([heard, term])
        return V2.similarity(m[heard], m[term])

    def reading(p, a, b, heard, term, rows, shared=False):
        acc, ref = [], []
        for u in rows:
            at = C.occurrence(u["span"], u["said"])
            v = place(parses[u["said"]], *at)[0] if at else None
            if v is not None:
                (ref if u["counter"] else acc).append(v)
        pair_acc, pair_ref = C.pairs(heard, term, rows, shared)
        v, span, toks = place(p, a, b)
        if not span:
            return None
        ca, cr = C.centroid(acc), C.centroid(ref)
        f = {"sim_acc": float(v @ ca) if v is not None and ca is not None else None,
             "sim_ref": float(v @ cr) if v is not None and cr is not None else None,
             "ner": C.ner_entity(ner, p, span), **C.pos_features(p, span),
             "sound": sound(heard, term), "known": known(heard),
             "pair_acc": pair_acc, "pair_ref": pair_ref}
        d, prob, z, _ = C.decide(model, f)
        clause = [min(p["starts"][k] for k in toks), max(p["ends"][k] for k in toks)] if toks else None
        return dict(decision=d, p=round(prob, 6), z=round(z, 6), clause=clause,
                    features={k: (round(x, 6) if x is not None else None) for k, x in f.items()})

    lines, close = [], []
    for it in todo:
        p = parses[it["text"]]
        a, b, heard = it["a"], it["b"], it["heard"]
        line = dict(id=it["id"])
        if not args.batch:
            line.update({k: it[k] for k in ("text", "a", "b", "heard", "term", "uses", "memory", "trim", "floor")
                         if k in it})
        if it.get("trim"):
            kept = C.trim_edges(p, it["text"], a, b, it["term"])
            if kept is None:
                lines.append(dict(line, declined="nothing left"))
                continue
            a, b = kept
            heard = it["text"][a:b]
            line["place"] = [a, b]
            if it.get("floor") is not None and sound(heard, it["term"]) < it["floor"]:
                lines.append(dict(line, declined="under the floor"))
                continue
        probs = []
        if it.get("memory"):
            members = {t: reading(p, a, b, heard, t, rows, shared=True) for t, rows in sorted(it["memory"].items())}
            d, what = C.decide_group([(t, r["p"], r["features"]["sim_acc"] is not None)
                                      for t, r in members.items()])
            line.update(members=members, group=dict(decision=d, terms=[what] if d == "write" else what or []))
            ps = sorted((r["p"] for r in members.values()), reverse=True)
            probs = [r["p"] for r in members.values()]
            if len(ps) > 1 and abs(ps[0] - ps[1] - C.GROUP_MARGIN) < MARGIN:
                close.append(it["id"])
                continue
        else:
            r = reading(p, a, b, heard, it["term"], it["uses"])
            if r is None:
                lines.append(dict(line, declined="no parser token at the place"))
                continue
            line.update(r)
            probs = [r["p"]]
        if any(min(abs(q - write), abs(q - leave)) < MARGIN for q in probs):
            close.append(it["id"])
            continue
        lines.append(line)
    args.out.write_text("[\n" + ",\n".join(json.dumps(x, ensure_ascii=False, separators=(",", ":")) for x in lines)
                        + "\n]\n")
    print(f"{len(lines)} items -> {args.out}; left out near a bound: {close}")

if __name__ == "__main__":
    main()
