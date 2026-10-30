#!/usr/bin/env python3
"""Write tests/clause-decider-parity.json: what the PyTorch clause decider answers.

    python scripts/clause-decider-reference.py --reference <syntax-parser dir> [--out FILE] [--batch FILE]

<syntax-parser dir> holds the training code the decider was fitted with
(vocab_clause_core, vocab_slots_core, vocab_clause_syrinx, vocab_gate_v2_data)
and the t-silver 42 checkpoint. Run it with that directory's venv; espeak-ng
must be installed, and the release binary built: `known` asks its
`--word-gate` about each letter run, since the word lists are NSSpellChecker
and wordpiece.txt. Those lists are scored by check-word-gate.sh, not here.
The weights are read from built-in/data/vocab-clause.safetensors and
vocab-slot.safetensors, the files the app bundles. `--batch` reads items in the same shape instead of the built-in
cases, for a local run on text that may not be committed.

An item: the text with the heard words in place, their scalar offsets a..b,
the heard words, the term, the term's stored rows (TermUses: said, span,
counter, heard) and the dictation language (default en). Every case below was
written for this repository.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / ".build/release/ParrotFlow"
WEIGHTS = ROOT / "built-in/data/vocab-clause.safetensors"
SLOT_WEIGHTS = ROOT / "built-in/data/vocab-slot.safetensors"
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
MIK_CODE = [
    use("Mik is writing the parser code this week.", "Mik"),
    use("Mik wrote the code for the migration script.", "Mik"),
    use("I paired with Mik on the build code yesterday.", "Mik"),
]
MICK = [
    use("Mick played the guitar at the wedding.", "Mick"),
    use("We went to see Mick play a concert downtown.", "Mick"),
    use("Mick is practising the drums for the gig on Friday.", "Mick"),
]
VENDOR = [
    use("We deploy the web app on Vercel every Friday.", "Vercel", heard="Versailles"),
    use("The Vercel preview build failed again this morning.", "Vercel"),
    use("I moved the API routes to Vercel last week.", "Vercel"),
]
# Rows shaped like the deploy sentences a user corrects Vercel in.
VENDOR_DEPLOY = [
    use("Tom deploys the new app on Vercel tonight.", "Vercel", heard="Versailles"),
    use("We deploy every preview build on Vercel.", "Vercel"),
    use("Sara deployed the API on Vercel yesterday.", "Vercel"),
]
CASTLE = "Anna deploys an app on Versailles while touring the Versailles Castle."
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
    # A past correction of this exact word in a deploy clause, read in a castle clause.
    ("vercel-castle-pair", "My grandmother loved the gardens of the Versailles castle near Paris.", "Versailles",
     "Vercel", VERCEL[:3] + [use("We moved the API routes to Vercel last month.", "Vercel", heard="Versailles")]),
    ("vercel-deploy-pair", "We deploy the staging app on Versailles every night.", "Versailles",
     "Vercel", VERCEL[:3] + [use("We moved the API routes to Vercel last month.", "Vercel", heard="Versailles")]),
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
    # A vendor and a castle heard the same way; one past correction of heard Versailles toward the vendor.
    ("group-vendor", CASTLE, 0, {"Vercel": VENDOR, "Versailles": []}),
    ("group-castle", CASTLE, 1, {"Vercel": VENDOR, "Versailles": []}),
    ("group-vendor-deploy-rows", CASTLE, 0, {"Vercel": VENDOR_DEPLOY, "Versailles": []}),
    ("group-castle-deploy-rows", CASTLE, 1, {"Vercel": VENDOR_DEPLOY, "Versailles": []}),
    # The same history, with Mik's sentences about writing code.
    ("group-history-code-rows-1", "Mick is writing code while Mick is playing the piano.", 0, {
        "Mick": MICK + [use("Mick tuned the old piano before the show.", "Mick", source="chosen")],
        "Mik": MIK_CODE + [use("Mik merged the branch after the review.", "Mik", heard="Mick"),
                           use("Mick tuned the old piano before the show.", "Mick", counter=True, source="chosen")]}),
    ("group-history-code-rows-2", "Mick is writing code while Mick is playing the piano.", 1, {
        "Mick": MICK + [use("Mick tuned the old piano before the show.", "Mick", source="chosen")],
        "Mik": MIK_CODE + [use("Mik merged the branch after the review.", "Mik", heard="Mick"),
                           use("Mick tuned the old piano before the show.", "Mick", counter=True, source="chosen")]}),
    # Mik was written over Mick once and the user put Mick back.
    ("group-put-back", "Mick is reviewing the setlist for tonight.", 0, {
        "Mick": MICK + [use("Mick sang two songs at the bar last night.", "Mick", heard="Mik")], "Mik": MIK}),
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
# The slot the parser reads where the heard words stand: (key, text, heard, term).
SLOTS = [
    ("slot-praise-adverb", "Praise his work has been amazing.", "Praise", "Praisy"),
    ("slot-praise-his", "Praise his work has been amazing.", "Praise his", "Praisy's"),
    ("slot-praise-verb", "We should praise his work.", "praise", "Praisy"),
    ("slot-praise-his-verb", "We should praise his work.", "praise his", "Praisy's"),
    ("slot-merge", "Go back to main and merge before lunch.", "merge", "Vercel"),
    ("slot-versus", "It was Postgres versus Mongo all week.", "versus", "Vercel"),
    ("slot-name", "I deploy the site on Versal every Friday.", "Versal", "Vercel"),
    ("slot-possessive", "I think Prise's work is great.", "Prise's", "Praisy's"),
    # The parser's argmax reads these names as AUX; the mask head opens them.
    ("slot-name-that", "It's the repo that Dalvi asked me to fix.", "Dalvi", "Dalvy"),
    ("slot-name-first", "Torvel put up the release notes.", "Torvel", "Torvell"),
    ("slot-adverb", "She quickly closed the ticket.", "quickly", "Quickly"),
]


# French, read with the French voice: (key, text, heard, term, rows).
VERCEL_FR = [
    use("On déploie le site sur Vercel chaque vendredi.", "Vercel", heard="Versal"),
    use("Le build de prévisualisation sur Vercel a encore échoué ce matin.", "Vercel"),
    use("J'ai déplacé les routes de l'API vers Vercel la semaine dernière.", "Vercel"),
    use("Nous avons visité le château de Versailles pendant les vacances.", "Versailles", counter=True),
]
MIRZA_FR = [
    use("Mirza a relu la pull request avant le déjeuner.", "Mirza"),
    use("J'ai demandé à Mirza de vérifier les notes de version.", "Mirza", heard="Mirsa"),
]
SUPABASE_FR = [
    use("On garde la table des utilisateurs dans Supabase.", "Supabase", heard="super base"),
    use("Le projet Supabase a la sécurité par ligne activée.", "Supabase"),
]
FRENCH = [
    ("fr-vercel-versal", "Je déploie mon application sur Versal tous les vendredis.", "Versal", "Vercel", VERCEL_FR),
    ("fr-vercel-castle", "Ma grand-mère adorait les jardins du château de Versailles.", "Versailles", "Vercel",
     VERCEL_FR),
    ("fr-mirza-murza", "Murza a préparé la migration de la base hier soir.", "Murza", "Mirza", MIRZA_FR),
    ("fr-ghostty-cold", "J'ai ouvert trois onglets dans Ghost T avant la démo.", "Ghost T", "Ghostty", []),
    ("fr-supabase-pair", "La clé super base a expiré hier.", "super base", "Supabase", SUPABASE_FR),
    ("fr-supabase-word", "Il a joué une super basse pendant le concert.", "super basse", "Supabase", SUPABASE_FR),
]
FRENCH_GROUPS = [
    ("fr-group-piano", "Pendant que Mick joue du piano, Mick relit les pull requests.", 1,
     {"Mick": MICK, "Mik": MIK}),
]
FRENCH_TRIMS = [
    ("fr-trim-sur", "Mik déploie l'application sur Versal cet après-midi.", "sur Versal", "Vercel", VERCEL_FR),
]
FRENCH_SLOTS = [
    ("fr-slot-verb", "Il faut fusionner la branche avant midi.", "fusionner", "Vercel"),
    ("fr-slot-name", "Je déploie le site sur Versal ce soir.", "Versal", "Vercel"),
    ("fr-slot-subject", "Précis a corrigé le build hier.", "Précis", "Praisy"),
]


def items(args):
    if args.batch:
        return json.loads(Path(args.batch).read_text())
    out = []
    for key, text, heard, term, rows in CASES:
        a = text.index(heard)
        out.append(dict(id=key, text=text, a=a, b=a + len(heard), heard=heard, term=term, uses=rows))
    for key, text, nth, members in GROUPS:
        heard = "Versailles" if "Versailles" in members else "Mick"
        a = [m.start() for m in re.finditer(rf"\b{heard}\b", text)][nth]
        out.append(dict(id=key, text=text, a=a, b=a + len(heard), heard=heard, term=heard, uses=[], memory=members))
    for key, text, heard, term, rows in TRIMS:
        a = text.index(heard)
        out.append(dict(id=key, text=text, a=a, b=a + len(heard), heard=heard, term=term, uses=rows, trim=True,
                        floor=FLOOR))
    for key, text, heard, term in SLOTS:
        a = text.index(heard)
        out.append(dict(id=key, text=text, a=a, b=a + len(heard), heard=heard, term=term, uses=[], masked=True))
    for key, text, heard, term, rows in FRENCH:
        a = text.index(heard)
        out.append(dict(id=key, text=text, a=a, b=a + len(heard), heard=heard, term=term, uses=rows, language="fr"))
    for key, text, nth, members in FRENCH_GROUPS:
        a = [m.start() for m in re.finditer(r"\bMick\b", text)][nth]
        out.append(dict(id=key, text=text, a=a, b=a + 4, heard="Mick", term="Mick", uses=[], memory=members,
                        language="fr"))
    for key, text, heard, term, rows in FRENCH_TRIMS:
        a = text.index(heard)
        out.append(dict(id=key, text=text, a=a, b=a + len(heard), heard=heard, term=term, uses=rows, trim=True,
                        floor=FLOOR, language="fr"))
    for key, text, heard, term in FRENCH_SLOTS:
        a = text.index(heard)
        out.append(dict(id=key, text=text, a=a, b=a + len(heard), heard=heard, term=term, uses=[], masked=True,
                        language="fr"))
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
    import numpy as np
    from safetensors.numpy import load_file
    from safetensors import safe_open

    import vocab_clause_core as C
    import vocab_slots_core as S
    import vocab_gate_v2_data as V2
    from vocab_clause_syrinx import Syrinx

    t = load_file(str(WEIGHTS))
    with safe_open(str(WEIGHTS), "np") as fh:
        meta = fh.metadata()
    names = json.loads(meta["features"])
    model = dict(names=names, w=t["w"].astype(float).tolist(), mu=t["mu"].astype(float).tolist(),
                 sd=t["sd"].astype(float).tolist(), bias=float(t["bias"][0]),
                 absent=dict(zip(json.loads(meta["absent"]), t["absent"].astype(float).tolist())),
                 fixed=dict(zip(json.loads(meta["fixed"]), t["fixed"].astype(float).tolist())),
                 one_sided=json.loads(meta.get("one_sided", "[]")), pair_gate=meta.get("pair_gate") == "sim_acc")
    write, leave = float(meta["write"]), float(meta["leave"])
    assert C.WRITE == write and C.LEAVE == leave and C.MIN_POOL == int(meta["min_pool"])
    centre, proj, ner = t["centre"], t["proj"], (t["ner.weight"], t["ner.bias"])
    head = load_file(str(SLOT_WEIGHTS))
    with safe_open(str(SLOT_WEIGHTS), "np") as fh:
        slot_meta = fh.metadata()
    assert slot_meta["input"] == "fused" and slot_meta["input_rounding"] == "float16"
    threshold = float(slot_meta["threshold"])

    ipa = {}
    unseen = {}

    def word_lists(heard):
        for run in re.findall(r"[^\W\d_]+", heard):
            if run not in unseen:
                out = subprocess.run([str(BINARY), "--word-gate", run], capture_output=True, text=True,
                                     check=True).stdout
                unseen[run] = "gate       auto-apply" in out
        return unseen.__getitem__

    def place(p, a, b):
        span = C.span_tokens(p, a, b)
        if not span:
            return None, span, []
        toks = C.pool_tokens(p, span)
        return C.vector(p, toks, centre, proj), span, toks

    syrinx = Syrinx()
    rows_of = lambda it: [u for rows in (it.get("memory") or {}).values() for u in rows] + it["uses"]
    parses = syrinx.analyse([it["text"] for it in todo] + [u["said"] for it in todo for u in rows_of(it)])

    def sound(heard, term, language):
        voice = C.voice(language)
        m = ipa.setdefault(voice, V2.IPA(voice)).of([heard, term])
        return V2.similarity(m[heard], m[term])

    def reading(p, a, b, heard, term, rows, language, shared=False, peers=()):
        acc, ref = [], []
        for u in rows:
            at = C.occurrence(u["span"], u["said"])
            v = place(parses[u["said"]], *at)[0] if at else None
            if v is not None:
                (ref if u["counter"] else acc).append(v)
        pair_acc, pair_ref = C.pairs(heard, term, rows, shared, peers)
        v, span, toks = place(p, a, b)
        if not span:
            return None
        ca, cr = C.centroid(acc), C.centroid(ref)
        f = {"sim_acc": float(v @ ca) if v is not None and ca is not None else None,
             "sim_ref": float(v @ cr) if v is not None and cr is not None else None,
             "ner": C.ner_entity(ner, p, span), **C.pos_features(p, span),
             "sound": sound(heard, term, language), "known": C.known(heard, word_lists(heard)),
             "pair_acc": pair_acc, "pair_ref": pair_ref}
        d, prob, z, _ = C.decide(model, f, shared=shared)
        clause = [min(p["starts"][k] for k in toks), max(p["ends"][k] for k in toks)] if toks else None
        return dict(decision=d, p=round(prob, 6), z=round(z, 6), clause=clause,
                    features={k: (round(x, 6) if x is not None else None) for k, x in f.items()})

    lines, close = [], []
    for it in todo:
        p = parses[it["text"]]
        a, b, heard = it["a"], it["b"], it["heard"]
        language = it.get("language", "en")
        line = dict(id=it["id"])
        if not args.batch:
            line.update({k: it[k] for k in ("text", "a", "b", "heard", "term", "uses", "memory", "trim", "floor", "masked",
                                            "language") if k in it})
        if it.get("trim"):
            kept = C.trim_edges(p, it["text"], a, b, it["term"])
            if kept is None:
                lines.append(dict(line, declined="nothing left"))
                continue
            a, b = kept
            heard = it["text"][a:b]
            line["place"] = [a, b]
            if it.get("floor") is not None and sound(heard, it["term"], language) < it["floor"]:
                lines.append(dict(line, declined="under the floor"))
                continue
        probs = []
        if it.get("memory"):
            members = {t: reading(p, a, b, heard, t, rows, language, shared=True,
                                  peers=[u for o, rs in it["memory"].items() if o != t for u in rs])
                       for t, rows in sorted(it["memory"].items())}
            d, what = C.decide_group([dict(term=t, p=r["p"], sim=r["features"]["sim_acc"],
                                           n=r["features"]["pair_acc"] - r["features"]["pair_ref"])
                                      for t, r in members.items()], heard)
            line.update(members=members, group=dict(decision=d, terms=[what] if d == "write" else what or []))
            probs = [r["p"] for r in members.values()]
        else:
            r = reading(p, a, b, heard, it["term"], it["uses"], language)
            if r is None:
                lines.append(dict(line, declined="no parser token at the place"))
                continue
            line.update(r)
            probs = [r["p"]]
        if it.get("masked"):
            words, at = S.masked_words(p, C.span_tokens(p, a, b))
            out = syrinx._rows([dict(words=words, text=" ".join(words))])[0]
            m = np.asarray(out["upos"][at], dtype=np.float64)
            q = S.nominal(head, out["x"][at].numpy())
            line["slot"] = dict(mask=[round(float(x), 6) for x in m], tag=S.tag(m), nominal=round(q, 6),
                                route="decline" if q < threshold else "open")
            if abs(q - threshold) < MARGIN:
                close.append(it["id"])
                continue
        if any(min(abs(q - write), abs(q - leave)) < MARGIN for q in probs):
            close.append(it["id"])
            continue
        lines.append(line)
    args.out.write_text("[\n" + ",\n".join(json.dumps(x, ensure_ascii=False, separators=(",", ":")) for x in lines)
                        + "\n]\n")
    print(f"{len(lines)} items -> {args.out}; left out near a bound: {close}")

if __name__ == "__main__":
    main()
