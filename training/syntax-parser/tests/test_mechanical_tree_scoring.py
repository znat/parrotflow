from eval_mechanical_tree_repair import score


def test_optional_cues_and_latest_deletion_scored_from_actual_edits():
    row = dict(label='repair', words=['I', 'I', 'leave'], token_starts=[0, 2, 4],
               token_ends=[1, 3, 9], abandoned_token_ids=[1], latest_token_ids=[2],
               proposed_output='I leave')
    good = score(row, dict(text='I leave', deleted_lexical_ids=[1]))
    assert good['lexical_repair_exact'] and good['text_exact'] and not good['latest_deleted']
    # Identical rendered text can conceal deletion of the wrong occurrence.
    bad = score(row, dict(text='I leave', deleted_lexical_ids=[2]))
    assert bad['text_exact'] and bad['latest_deleted'] and bad['outside_lexical_deletion']
    assert not bad['lexical_repair_exact']
