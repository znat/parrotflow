"""Frozen epoch5 predictions: compare deterministic postprocessing strategies."""
import json
from pathlib import Path
from collections import defaultdict
from hashlib import sha256

from mechanical_tree_repair import repair, MODES
from repair_structures import lexical


def read(path):
    return json.loads(Path(path).read_text())


def digest(path):
    return sha256(Path(path).read_bytes()).hexdigest()


def score(row, output):
    deleted = set(output['deleted_lexical_ids'])
    if row['label'] == 'keep':
        return dict(keep_changed=output['text'] != row['text'])
    if row['label'] != 'repair':
        return dict(ambiguous_changed=output['text'] != row['text'])
    abandoned = set(row['abandoned_token_ids'])
    cues = {i for i, (word, a, b) in enumerate(zip(row['words'], row['token_starts'], row['token_ends']), 1)
            if lexical(word) and any(c['start'] <= a and b <= c['end'] for c in row.get('cue_spans', []))}
    allowed = abandoned | cues
    return dict(repair_attempted=bool(deleted),
                lexical_repair_exact=abandoned <= deleted <= allowed,
                text_exact=output['text'] == row['proposed_output'],
                outside_lexical_deletion=bool(deleted-allowed),
                latest_deleted=bool(deleted & set(row['latest_token_ids'])),
                abandoned_recovered=len(deleted & abandoned), abandoned_total=len(abandoned))


def main():
    out = Path('artifacts/mechanical-tree-repair-v1')
    assert not out.exists(), 'Never overwrite a scored experiment'
    pred_path = Path('artifacts/stanza-raw11-epochs5/epoch5-evaluation.json')
    files = [Path(__file__), Path('mechanical_tree_repair.py'), Path('repair_structures.py'), pred_path]
    files += [Path(f'artifacts/repair-corpus-{n}/heldout.json') for n in ('v2', 'v3')]
    frozen = {str(p): digest(p) for p in files}
    out.mkdir()
    protocol = dict(source_sha256=frozen, checkpoint='stanza-raw11-epochs5/epoch5.pt', modes=MODES,
        scope='Offline experiment on supplied token boundaries and frozen predicted trees; English only.',
        selection='Fixed rules before this scoring run; no per-example gold labels enter inference.',
        rules='Adjacent identical spans up to6 words; tree role agreement/forward reparandum, closed-class singleton filter. '
              'Explicit no/sorry I mean cues, contiguous earlier subtree <=6 words, compatible later root, no earlier subject. '
              'Reject conflicts and deletion of predicted latest targets. No uncued lexical substitutions.',
        evaluation='Previously inspected weak diagnostic labels, not an independent test; v3 contains correlated template variants.',
        gold_usage='Only in score(), after repair() returns. Latest safety checked against gold independently of inferred targets.')
    (out/'protocol.json').write_text(json.dumps(protocol, indent=2))
    predictions = read(pred_path)
    report = {}
    for name in ('v2', 'v3'):
        rows = read(f'artifacts/repair-corpus-{name}/heldout.json')
        report[name] = {}
        for mode in MODES:
            totals = defaultdict(int)
            details = []
            for row in rows:
                output = repair(row['text'], row['words'], **predictions[name]['predictions'][row['id']], mode=mode)
                metrics = score(row, output)
                for k, v in metrics.items():
                    totals[k] += int(v)
                totals[row['label']+'_records'] += 1
                details.append(dict(id=row['id'], label=row['label'], category=row['category'],
                                    input=row['text'], expected=row['proposed_output'], output=output, metrics=metrics))
            report[name][mode] = dict(metrics=dict(totals), details=details)
    report['history'] = []
    for row in predictions['history']:
        output = repair(row['text'], row['words'], row['heads'], row['labels'])
        report['history'].append(dict(case_id=row['case_id'], input=row['text'], output=output))
    assert all(digest(p) == h for p, h in frozen.items())
    (out/'results.json').write_text(json.dumps(report, indent=2, ensure_ascii=False))
    lines = ['# Réparation mécanique sur les arbres de l’époque 5', '',
             'Expérience hors production, sans réentraînement ni spaCy. Les règles reçoivent uniquement '
             'le texte, les mots et l’arbre prédit. Les annotations de référence servent ensuite au score.', '',
             '| Jeu / méthode | Reprises lexicales exactes | Texte exact | Phrases correctes modifiées | Dernière formulation touchée |',
             '|---|---:|---:|---:|---:|']
    for name in ('v2', 'v3'):
        for mode in MODES:
            m = report[name][mode]['metrics']
            lines.append(f"| {name} / {mode} | {m.get('lexical_repair_exact',0)}/{m['repair_records']} | "
                         f"{m.get('text_exact',0)}/{m['repair_records']} | {m.get('keep_changed',0)}/{m['keep_records']} | "
                         f"{m.get('latest_deleted',0)}/{m['repair_records']} |")
    lines += ['', 'Une reprise lexicale exacte retire tous les mots abandonnés et aucun autre mot, '
              'sauf les marqueurs de correction annotés. Le texte exact exige aussi le bon nettoyage des '
              'marqueurs, espaces et ponctuation. Le score de suppression diffère donc du précédent score '
              'd’arc reparandum ; il mesure ici les mots effectivement retirés.', '',
              '## Méthodes', '',
              '- unchanged : ne rien modifier.',
              '- text_repeat : supprimer la première occurrence de répétitions adjacentes exactes, sans critère syntaxique.',
              '- reparandum : retirer les sous-arbres lexicaux marqués reparandum, si le parent est ultérieur et protégé ; sans nettoyage des marqueurs.',
              '- tree_exact : répétitions adjacentes, filtrées par rôle syntaxique et limites du sous-arbre ; filtre lexical pour les mots isolés afin d’éviter l’emphase.',
              '- tree_cued : reprises introduites par no/sorry I mean et soutenues par l’arbre.',
              '- tree_combined : union des deux dernières règles, avec rejet des conflits.', '',
              'Les règles ne suppriment pas un segment simplement parce qu’il occupe un rôle semblable à un autre. '
              'Les substitutions sans marqueur restent à juger. La protection interne vise les segments finaux '
              'inférés ; sa justesse est vérifiée séparément contre les spans annotés.', '',
              '## Sorties de la méthode combinée', '']
    for name in ('v2', 'v3'):
        rows = report[name]['tree_combined']['details']
        changed = [r for r in rows if r['output']['edits']]
        failures = [r for r in changed if r['metrics'].get('keep_changed') or r['metrics'].get('outside_lexical_deletion')]
        successes = [r for r in changed if r['metrics'].get('lexical_repair_exact')]
        for title, samples in [('Corrections', successes[:3]), ('Suppressions injustifiées', failures[:8])]:
            lines += [f'### {name} — {title}', '']
            for r in samples:
                lines += [f"- Entrée : {r['input']}", f"  Sortie : **{r['output']['text']}**", f"  Attendu : {r['expected']}"]
            if not samples:
                lines.append('Aucun cas dans cette catégorie.')
            lines.append('')
    lines += ['## Exemples initiaux', '']
    for row in report['history']:
        if row['case_id'] in (22, 23):
            lines.append(f"- {row['input']} → **{row['output']['text']}**")
    lines += ['', '## Limites', '',
              'Les jeux v2/v3 portent des annotations locales faibles déjà examinées. V3 comprend surtout '
              'des variantes proches de quelques répétitions de préfixes ; ses scores ne mesurent pas '
              'une généralisation à toutes les hésitations. Les mots sont présegmentés. '
              'Ce test n’ajoute aucune règle au pipeline de production.', '',
              'Les empreintes des règles, des prédictions et des données ont été fixées avant le score et '
              'revérifiées après. Les sorties détaillées, y compris les abstentions et les erreurs, sont '
              'dans artifacts/mechanical-tree-repair-v1/results.json.', '']
    Path('MECHANICAL_TREE_REPAIR.md').write_text('\n'.join(lines))
    print('\n'.join(lines[4:18]))


if __name__ == '__main__':
    main()
