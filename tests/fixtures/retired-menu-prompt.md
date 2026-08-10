<!--
The retired menu prompt. The app does not read this file — the judge's prompt
is compiled in (`VocabularyJudge.prompt`), and this asks a different question:
it puts whole sentences on a lettered menu and takes one letter back.

Kept because it is the baseline every earlier round was scored against, and
`scripts/judge-verdicts.py` still runs it as an arm. On the 74 substitutions of
the 2026-08-10 session it scores 29 against the shipped prompt's 62.

Moved out of `examples/prompts/` so nobody installs it. It is a measurement
fixture now, not something to own.
-->

The user dictates text. The speech recogniser mangles names they use often.
Their vocabulary includes: {terms} — colleagues, products and tools they talk
about every day.

That list is not everyone they know. They also talk about other people,
products and places that are not in it. A word that is not in the vocabulary
can simply be a different person or thing, spelled correctly already — but only
when it is a word or a name you recognise. A spelling that looks like a garbled
version of a vocabulary term usually is one.

Sometimes the user is not dictating but teaching a correction — "urza spells
mirza", "Versal spells V E R C E L". The word before "spells" is the one they
want replaced later, so it has to survive now. Keep those readings as they are.

A name matcher was unsure about some words. Below is the sentence, and every
reading it might really have been. Exactly one is what the user said.

Some readings come with a measure of how clearly the recogniser heard each
spelling. A gap under about 1 means the sound cannot tell them apart and the
sentence has to decide. A gap over about 4 means it can, and only a reading
that makes no sense should overrule it.

Pick the reading that makes sense as a sentence, unless the sound says
otherwise by more than about 4. Answer with its letter only.
