import copy
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import import_reviewed_multilingual_v1 as imp

# Corpus-level checks are opt-in when the separately distributed review artifacts exist.
_required = list(imp.SOURCES.values()) + imp.REVIEWS + [imp.FOLLOWUP]
pytestmark = pytest.mark.skipif(
    any(not (imp.ROOT / name).is_file() for name in _required),
    reason="Reviewed corpus artifacts are not distributed in the source PR",
)


@pytest.fixture(scope='module')
def dataset():
    rows, failures = imp.construct()
    assert not failures
    return {(r['language'], r['source_id']): r for r in rows}


@pytest.fixture(scope='module')
def inputs():
    return imp.load_inputs()


def test_complete_coverage_split_locks_and_normalized_leakage(dataset, inputs):
    imp.validate_dataset(list(dataset.values()), inputs[0])
    assert len(dataset) == 1412


def test_exact_adjudicated_eligibility(dataset):
    from collections import Counter
    expected = {
        'en': {'full_tree': 349, 'exclude_pending_review': 4},
        'fr': {'full_tree': 329, 'diagnostic_only': 16, 'exclude_pending_review': 8},
        'es': {'full_tree': 330, 'diagnostic_only': 15, 'exclude_pending_review': 8},
        'ca': {'full_tree': 319, 'diagnostic_only': 26, 'exclude_pending_review': 8},
    }
    for language, counts in expected.items():
        assert Counter(r['supervision_recommendation'] for (lang, _), r in dataset.items() if lang == language) == counts


def test_english_bare_no_restored_but_mean_not_supervised(dataset, inputs):
    for source in inputs[0]['en']:
        sid = source['id']
        if source['family_id'] not in imp.POLICY_FAMILIES or not sid.endswith('-repair-unpunctuated'):
            continue
        r = dataset['en', sid]
        assert r['intended_output'] == source['intended_output']
        assert r['heads'] == source['heads'] and r['labels'] == source['labels']
        assert r['syntax_training_eligible'] == ('-03-' not in sid)
        if '-03-' in sid:
            assert r['alternative_keep_target'] == r['text']
            assert r['runtime_policy'] == 'preserve_input_due_to_ambiguity'


def test_unpunctuated_sorry_not_accidentally_excluded(dataset):
    for (lang, sid), r in dataset.items():
        if r['family_id'] in imp.POLICY_FAMILIES and sid.endswith('-02-repair-unpunctuated'):
            assert r['syntax_training_eligible'], (lang, sid)


def test_french_single_word_cue_reverts_h8(dataset, inputs):
    checked = 0
    for source in inputs[0]['fr']:
        sid = source['source_id']
        cue = imp.role_ids(source, 'cue')
        if len(cue) != 1:
            continue
        r = dataset['fr', sid]
        mapping = r['review_provenance']['old_to_new_token_ids']
        for patch in inputs[1]['fr', sid]['token_head_relation_changes']:
            if 'H8' not in patch['why']:
                continue
            node = mapping[str(patch['id'])][0]
            old_head = source['heads'][patch['id']-1]
            assert r['heads'][node-1] == mapping[str(old_head)][0]
            checked += 1
    assert checked == 114


def test_catalan_splits_have_real_maps_and_final_cue_heads(dataset):
    rows = 0
    for (lang, _), r in dataset.items():
        if lang != 'ca':
            continue
        locution_splits = [p for p in r['review_provenance']['applied_and_withheld_patches'] if p['action']=='split_contraction' and r['review_provenance']['review_row']['source_id'] not in {
            'htd1-adjective-copular-complement-05-repair','htd1-adjective-copular-complement-05-keep'}]
        if not locution_splits:
            continue
        rows += 1
        for patch in locution_splits:
            ids = r['review_provenance']['old_to_new_token_ids'][str(patch['old_id'])]
            assert [r['words'][i-1] for i in ids] == ['a', 'el']
            assert [r['labels'][i-1] for i in ids] == ['case', 'det']
            assert r['heads'][ids[0]-1] == r['heads'][ids[1]-1]
            head = r['heads'][ids[0]-1]
            assert r['words'][head-1] in ('costat', 'voltant')
        cue = set(r['cue_token_ids'])
        if cue:
            head = next(i for i in cue if r['heads'][i-1] not in cue)
            for i in (min(cue)-1, max(cue)+1):
                if r['words'][i-1] == ',':
                    assert r['heads'][i-1] == head
    assert rows == 53


def test_mes_aviat_degree_policy_all_twelve(dataset):
    count = 0
    for (lang, _), r in dataset.items():
        if lang != 'ca':
            continue
        for i in range(len(r['words'])-1):
            if r['words'][i:i+2] == ['més','aviat']:
                assert r['labels'][i] == 'advmod'
                assert r['heads'][i+1] == i+1 and r['labels'][i+1] == 'fixed'
                count += 1
    assert count == 12


def test_added_removed_words_and_independent_targets(dataset):
    r = dataset['fr','htd1-infinitive-controlled-marked-exposed-04-repair']
    for verb in ('remplacer','nettoyer'):
        i = r['words'].index(verb)
        assert r['words'][i-1] == 'de'
        assert r['heads'][i-1] == i+1 and r['labels'][i-1] == 'mark'
    assert r['intended_output'] == 'Nous prévoyions de nettoyer les tuiles près de la cheminée.'
    assert 'doucement' not in dataset['fr','htd1-adjective-adjective-infinitive-complement-02-repair']['words']
    r = dataset['es','htd1-clause_restart-bare-clause-exposed-01-keep']
    assert ', pero' in r['text'] and r['text']==r['intended_output']
    r = dataset['ca','htd1-adjective-sensory-predicate-exposed-01-repair']
    assert r['intended_output']=='La sopa sembla massa salada per a mi.'


def test_diagnostic_only_edges_and_original_hi_ha(dataset):
    for (lang, _), r in dataset.items():
        if lang in ('es','ca') and r['family_id']=='clausal-subject':
            assert r['supervision_recommendation']=='diagnostic_only'
    r=dataset['ca','safety-v2-nonstandard-existential']
    assert r['text'].startswith('Hi ha ') and 'han' not in r['words']
    assert r['current_review_decision']=='unsupported'
    assert r['labels'][0]=='obl' and r['heads'][0]==2


def test_preserved_deliberate_errors_sws_and_no_false_pos_gold(dataset,inputs):
    for source in inputs[0]['en']:
        if 'attributive-degree-05' in source['id']:
            r=dataset['en',source['id']]
            assert r['text']==source['text'] and r['intended_output']==source['intended_output']
    for r in dataset.values():
        assert not r['pos_supervision_complete'] and not r['morphology_supervision_complete']
        assert not r['training_ready'] and not r['human_reviewed']
    r=dataset['es','user-sws-causal-clause-restart'] if ('es','user-sws-causal-clause-restart') in dataset else None
    if r:assert not r['text'].startswith('ya no es cierto')


@pytest.mark.parametrize('corruption',['cycle','latest_deletion','partial_mwt','wrong_target','false_gold'])
def test_validator_rejects_semantic_mapping_corruption(dataset,corruption):
    r=copy.deepcopy(dataset['ca','htd1-infinitive-controlled-marked-exposed-01-repair'])
    if corruption=='cycle':r['heads'][0]=1
    if corruption=='latest_deletion':r['delete_spans'][0]['end']=r['latest_span']['end']
    if corruption=='partial_mwt':r['delete_spans'][0]['start']+=1
    if corruption=='wrong_target':r['intended_output']+=' invented'
    if corruption=='false_gold':r['human_reviewed']=True
    with pytest.raises(AssertionError):imp.validate(r)


def test_source_hash_checked_before_patch_and_conllu_export(inputs,dataset):
    source=copy.deepcopy(next(r for r in inputs[0]['en'] if r['id']=='htd1-adjective-sensory-predicate-exposed-01-repair'))
    review=copy.deepcopy(inputs[1]['en',source['id']])
    if review['token_head_relation_changes']:
        review['token_head_relation_changes'][0]['word']='incorrect source word'
        with pytest.raises(AssertionError):imp.build_record(source,review,'en')
    text=imp.conllu([dataset['ca','htd1-noun_preposition-oblique-location-exposed-01-repair']])
    assert '\tal\t_\t_' in text
    assert '# supervision = full_tree' in text
