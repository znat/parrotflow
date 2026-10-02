# Vocabulary: names the app gets wrong

A name, a project or a term the recogniser mangles goes in `vocabulary.yaml`,
beside `config.yaml`. One entry covers renderings never seen: it is matched by
sound, and each match is checked against the sentence before it is written. A
table in `replace:` is the wrong tool for a name. It fires on every sentence,
even where the ordinary word was meant.

## When to offer it

- **Right after any edit to the Slack roster.** The roster matches spelling.
  A name the recogniser writes another way is never tagged. Offer to add each
  roster name that is not an ordinary word.
- **When the user says a name keeps coming out wrong.**
- When any rewrite depends on a name being spelled right.

Say that the names stay on their Mac. Nothing in this file leaves it.

## Add terms

Back up first: `cp "<config_dir>/vocabulary.yaml" "<config_dir>/vocabulary.yaml.bak-$(date +%Y%m%d-%H%M%S)"`.
The file says "do not edit" because the app writes it. Adding terms by hand is
the intended path; say so.

A term with nothing more to say is a bare key under `terms:`. A new file has
`terms: {}`; replace the `{}`.

```yaml
terms:
  Tasmeen:
  Supabase:
```

A known mishearing, from a terminal. It adds the term and the rendering:

```sh
"$PF" --learn "super base" Supabase
```

The user can do the same while dictating, with no agent:

- **The panel**: select the wrong word, hold the hotkey, say "hey parrot". A
  row shows what was heard and what it should be. Needs no model.
- **Spelling out loud**: "hey parrot, Tasmin spells T A S M E E N", or "hey
  parrot, Jerome with a G". Needs a model. The panel opens prefilled.

Check with `"$PF" --check-config`. It counts the terms:
`vocabulary: 2 terms in vocabulary.yaml, 2 matched by sound, 1 by rule`. A
misspelt key in `vocabulary.yaml` is ignored in silence, so write only the keys
shown here.

Then ask for one real dictation with the name in the middle of a sentence.

## A term that writes over an ordinary word

Some names sound exactly like a word: "Claude" and "cloud". No sound match can
tell them apart. When a term keeps replacing a word that was meant, turn its
sound match off:

```yaml
terms:
  Claude:
    floor: off
```

The term is then written only from its `pronunciations`, as exact rules. Never
list an ordinary word there: a rule fires on every sentence.

## A first list

The `vocabulary-corpus` skill, when installed, builds a first vocabulary from a
codebase and a Slack workspace. Use it for a new setup or a new project.

## Settings for the pass

They are in `config.yaml`, not in `vocabulary.yaml`:

```yaml
transcription:
  vocabulary:
    enabled: true
    sound_below: 0.85     # how close a run of words must sound to a term
    asks: true            # ask before typing a name it could not settle
```

Leave the other keys there alone. They exist to switch off half the pass for
measuring.
