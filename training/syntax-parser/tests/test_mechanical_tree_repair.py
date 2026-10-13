from mechanical_tree_repair import repair
from repair_structures import tokenize


def run(text, heads, labels, mode='tree_combined'):
    return repair(text, tokenize(text)[0], heads, labels, mode)


def test_repeated_marker_same_slot_keeps_latest_without_reparandum():
    result = run('if if we leave', [4, 4, 4, 0], ['mark', 'mark', 'nsubj', 'root'])
    assert result['text'] == 'if we leave'
    assert result['deleted_lexical_ids'] == [1]
    assert result['edits'][0]['protected_ids'] == (2,)


def test_distinct_grammatical_roles_and_emphasis_stay():
    assert run('I know that that works', [2, 0, 5, 5, 2],
               ['nsubj', 'root', 'mark', 'nsubj', 'ccomp'])['edits'] == []
    assert run('It is very very good', [5, 5, 5, 5, 0],
               ['nsubj', 'cop', 'advmod', 'advmod', 'root'])['edits'] == []
    assert run('I had had enough', [3, 3, 0, 3],
               ['nsubj', 'aux', 'root', 'obj'])['edits'] == []


def test_multitoken_repeat_and_explicit_cue():
    result = run('the dog the dog ran', [2, 4, 4, 5, 0],
                 ['det', 'reparandum', 'det', 'nsubj', 'root'])
    assert result['text'] == 'the dog ran'
    assert result['deleted_lexical_ids'] == [1, 2]
    # Spurious outer reparandum must not delete the sentence subject/predicate.
    text = 'The surface feels rather rough, no, I mean very smooth.'
    heads = [2, 3, 12, 5, 12, 7, 12, 7, 10, 12, 12, 0, 12]
    labels = ['det', 'nsubj', 'reparandum', 'advmod', 'reparandum', 'punct',
              'discourse', 'punct', 'nsubj', 'parataxis', 'advmod', 'root', 'punct']
    result = run(text, heads, labels)
    assert result['text'] == 'The surface feels very smooth.'
    assert result['deleted_lexical_ids'] == [4, 5, 7, 9, 10]


def test_no_cue_does_not_turn_similar_slots_into_substitution():
    text = 'I want to write to edit the code'
    result = run(text, [2, 0, 4, 2, 6, 4, 8, 6],
                 ['nsubj', 'root', 'mark', 'xcomp', 'mark', 'xcomp', 'det', 'obj'])
    assert result['text'] == text and result['edits'] == []


def test_malformed_tree_fails_open():
    for heads in ([2, 1], [0, 0], [3, 0], [0]):
        result = run('I I', heads, ['nsubj', 'nsubj'])
        assert result['text'] == 'I I' and result['edits'] == []
        assert result['error']


def test_overlapping_chain_never_deletes_final_repetition():
    result = run('if if if we leave', [5, 5, 5, 5, 0],
                 ['mark', 'mark', 'mark', 'nsubj', 'root'])
    assert 3 not in result['deleted_lexical_ids']
    assert result['text'].endswith('if we leave')


def test_text_control_exposes_emphasis_risk():
    result = run('very very good', [3, 3, 0], ['advmod', 'advmod', 'root'], 'text_repeat')
    assert result['text'] == 'very good'
