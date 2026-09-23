# How vocabulary works

Your teammate Mik writes code. Your friend Mick plays guitar. A global
“Mick → Mik” replacement would fix one sentence and break the other.

ParrotFlow's vocabulary pass considers candidate spellings in context. Teach
it your names, projects, and tools; review corrections so it has evidence about
where a term belongs. This is contextual matching, not a guarantee that every
similar-sounding name will be resolved correctly.

## Teach a spelling

1. Select the misheard text in the app where it appeared.
2. Hold your dictation hotkey—**Right Command** by default—and say **“hey parrot.”**
3. Check the **Heard as** and **Should be** fields.
4. Save the correction.

You can edit both fields. If “super base” should be “Supabase,” include the
whole phrase on the left. A word the dictionary already recognizes may not be
suggested automatically; add or edit a row yourself.

Saving writes the confirmed vocabulary to `vocabulary.yaml` beside your config
and attempts to put the corrected text back in its original field. It does not
require you to rewrite `config.yaml`.

## Why context matters

Matching starts with renderings you have taught and can consider near matches
and pronunciation. Further checks decide whether the candidate fits the word
and sentence. Confirmed uses and counter-examples help distinguish the contexts
where a term belongs from those where it does not.

If ParrotFlow inserts a term in the wrong context, correct it back. A reverse
correction is not turned into an endless pair of opposing replacements; it can
provide evidence against that use of the term.

Keep vocabulary for terms and names. Grammar changes such as “users” to “user”
are a different job and should not become pronunciation rules.

## Say the correction instead

You can also describe or spell a correction:

> “Hey parrot, Mick is spelled M I K.”

The app prepares a correction for you to confirm. This path needs a configured
language model to interpret the instruction. The simple “hey parrot” command
that opens the vocabulary panel works without one.

For local operation, configure a local model. If you choose a remote provider,
the text needed for the command is sent to that provider.

[Models and privacy](configuration.md#models-and-privacy)

## Undo an unwanted edit

Say **“hey parrot, undo”** to reverse the most recent supported substitution.
This literal command does not need a model. The app checks the original field
and refuses if the text has changed since; it is not a general edit history.

Undoing an edit is different from deleting a saved vocabulary entry. To change
what is remembered, inspect `vocabulary.yaml` through **Settings → Open Config
Folder**. Back it up before editing and validate your configuration afterward.

## When something does not work

| Symptom | What to check |
| --- | --- |
| The panel misses an ordinary word used as a name | Add the correction manually; dictionary-based suggestions cannot catch every case. |
| The app cannot read or replace a selection | Check Accessibility permission. |
| A terminal loses the selection | Copy it first, then invoke the correction. |
| A described correction cannot run | Check the configured model and its availability. |
| A term is applied in the wrong context | Correct it back and inspect the saved vocabulary rather than adding a reverse global rule. |

## Your data

Vocabulary is stored locally. Dictation and correction traces can also contain
your text and surrounding context. Review [logging controls](configuration.md#logs-and-recordings)
before sharing a report or working with sensitive material.

## Go deeper

[Matching and context reference](../pipelines.md#the-name-stage) ·
[Correction behavior and edge cases](../corrections.md) · [All guides](../README.md)
