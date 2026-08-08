# Four ways to ask the judge — what each one is worth

**Nothing won. Do not change the prompt.**

The shipped prompt scores 41/53 on the cached menus, against a chance of
17.4/53. Ten framings were measured. The best scored 42/53 and the worst 35.
A win of one case is noise: F16 measured five wordings of a single sentence
spanning 38 to 42. The same 53 cases were tuned on and reported on. There is
no held-out set.

One number did move. On the nine clips where an ordinary English word was
overwritten by a vocabulary term, **the shipped prompt gets 0 of 8**
(the ninth was never on its menu). Adding one paragraph about where a name can
stand takes 2 of the 8 and costs nothing overall. Deleting the term list takes
4 of the 8 and costs 3 cases overall.

That trade is the finding. The term list is what tells the judge that `Praisy`
is a spelling at all. Remove it and the judge writes `Prissy`. Keep it and the
judge writes `Praisy` where the speaker said "praise". **One sentence cannot
serve both, so this is a mechanism to change, not a prompt to reword.**

Measured with `scripts/judge-framings.py` against `tests/judge-menus.json`,
`gemma4:e4b`, temperature 0, nothing else loaded. No build, no install.

---

## The four questions, in full

### 1. Baseline — the shipped prompt

```
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
```

`{terms}` is filled in per case, e.g. `Praisy, Praisy's` or `Redcrawl., Tasmeen`.

**41/53. 0/8 of the collision class.**

### 2. No term list — two wordings

Only the first paragraph changes. Everything else is the baseline.

```diff
 The user dictates text. The speech recogniser mangles names they use often.
-Their vocabulary includes: {terms} — colleagues, products and tools they talk
-about every day.
+Their vocabulary includes colleagues, products and tools they talk about
+every day. The names in it are not listed here.
```

**36/53. 3/8.** And the sentence deleted outright, with the pointer to it
repaired:

```diff
 The user dictates text. The speech recogniser mangles names they use often.
-Their vocabulary includes: {terms} — colleagues, products and tools they talk
-about every day.

-That list is not everyone they know. They also talk about other people,
+Their vocabulary is not everyone they know. They also talk about other people,
```

**38/53. 4/8.**

### 3. Inverted polarity — three wordings

Only the last paragraph changes. Ported from `rerank-judge.py`'s `misheard`
family, which F14 measured as the polarity that works for a reranker.

```diff
-Pick the reading that makes sense as a sentence, unless the sound says
-otherwise by more than about 4. Answer with its letter only.
+Every reading but one contains a speech-recognition error: a proper name or
+product name written where an ordinary English word was actually spoken,
+leaving a sentence that does not parse. Rule those readings out. Answer with
+the letter of the one that is left, unless the sound says otherwise by more
+than about 4.
```

**35/53. 1/8.** Short:

```
All but one of these readings contain a transcription error. Rule them out.
Answer with the letter of the one that does not, unless the sound says
otherwise by more than about 4.
```

**35/53. 0/8.** Long:

```
In all but one of these readings, a brand, product or person's name is
printed where the speaker actually said a common English word, or two common
words have been run together into a single name — leaving a sentence a native
speaker would never produce. Find those readings and rule them out. Answer
with the letter of the reading that is left, unless the sound says otherwise
by more than about 4.
```

**38/53. 1/8.**

### 4. Typed terms, and a rule about position

The list carries a kind, from `tests/term-kinds.yaml`:

Only `{terms}` changes. The sentence around it is the shipped one.

```diff
-Their vocabulary includes: Praisy, Praisy's — colleagues, products and tools they talk
+Their vocabulary includes: Praisy (a person), Praisy's (a person) — colleagues, products and tools they talk
 about every day.
```

**40/53. 0/8** on its own. With one paragraph added before the final one:

```
Each name above is labelled with what kind of thing it is. A name can only
stand where a name of that kind can stand. A product, a brand or a drug is
not a verb, so it cannot follow "to" as an infinitive, and it does not
modify a noun the way an adjective does. A person is not an adjective
either. A reading that puts a name in a position no name of its kind can
occupy is not what the user said.
```

**42/53. 2/8.** The same paragraph with the kinds taken out, on the ordinary
bare list:

```
A name can only stand where a name can stand. A name is not a verb, so it
cannot follow "to" as an infinitive, and it does not modify a noun the way
an adjective does. A reading that puts a name in a position no name can
occupy is not what the user said.
```

**41/53. 2/8.** So the labels are worth nothing and the question is worth 2 of
the 8.

---

## Three real cases

Verbatim from `tests/judge-menus.json`. The score block is what the judge was
shown, in the user message.

### Fixed by the position rule — `13-09-46`

```
said: The team deserves praise for shipping that fast.
terms: Praisy, Praisy's

  A. The team deserves praise for shipping that fast.
  B. The team deserves Praisy shipping that fast.
  C. The team deserves Praisy's shipping that fast.

  "praise" -8.70   "Praisy" -10.49   — "Praisy" heard 1.8 less clearly
```

| arm | chose |
|---|---|
| baseline | **B** — "deserves Praisy shipping" |
| inverted, all three | B or C |
| typed, no rule | B |
| position rule (typed or bare) | **A** ✓ |
| no term list | **A** ✓ |

The sound already says "praise" by 1.8 nats. The shipped prompt overrides it
anyway. "deserves Praisy shipping" is not English, and only the arms that ask
about position or hide the list notice.

### Wrong in every arm — `10-12-37`

```
said: It's a community that Tasmeen asked me to crawl.
terms: Redcrawl., Tasmeen

  A. It's a community that Tasmin asked me to crawl.
  B. It's a community that Tasmin asked me to Redcrawl.
  C. It's a community that Tasmeen asked me to crawl.
  D. It's a community that Tasmeen asked me to Redcrawl.

  "Tasmin" -10.13   "Tasmeen" -10.68   — "Tasmeen" heard 0.5 less clearly
  "crawl." -10.06   "Redcrawl." -11.83   — "Redcrawl." heard 1.8 less clearly
```

Every arm takes **D**, except the two that hide the list, which take **A** and
lose `Tasmeen` instead. The sentence has two slots. One name is right and one
is wrong, and no framing tried can say different things about them, because
every option carries both. This is the case that argues for a per-slot
question.

### Broken by a new arm — `07-36-58`

```
said: So let's say we have very low floor for Praisy, but with the judge. ...
terms: Praisy
(no score block — the router proposed this from spelling alone)

  A. So let's say we have very low floor for Prezi, but with the judge. ...
  B. So let's say we have very low floor for Praisy, but with the judge. ...
```

Baseline, all three inverted arms and typed-without-a-rule take **B** ✓. The
position rule takes **A**, and so does every arm without the term list. The
speaker is talking *about* their vocabulary term, so the name really is in a
noun slot, and with no acoustic evidence the list is all there is. PR #68 lost
this same clip when it ablated the pro-term sentence.

---

## The ordinary-word collision class

The nine clips PR #68 recorded as regressed. Five are also the controls at `~`
in `menu-recall.py` (`11-19-17`, `14-04-21`, `14-09-56`, `15-36-12`,
`13-09-46`).

| clip | said → written | ships | no list | inverted | typed | + rule |
|---|---|---|---|---|---|---|
| `17-47-45` | retry/crawl → Arexvy/Redcrawl | ✗ | ✗ | ✗ | ✗ | ✗ |
| `09-35-01` | Versailles → Vercel castle | never reached a menu ||||| |
| `14-04-21` | to update → to Supabase | ✗ | ✗ | ✗ | ✗ | ✗ |
| `10-12-37` | to crawl → to Redcrawl | ✗ | ✗ | ✗ | ✗ | ✗ |
| `14-09-56` | near matches → near Matthieu | ✗ | ✗ | ✗ | ✗ | ✗ |
| `13-09-46` | praise for → Praisy | ✗ | ✓ | ✗ | ✗ | ✓ |
| `11-19-17` | proprietary → Praisy | ✗ | ✓ | ✗ | ✗ | ✓ |
| `15-36-12` | Pretty → Arexvy | ✗ | ✓ | ✓ | ✗ | ✗ |
| `14-11-21` | the crawl → the Redcrawl | ✗ | ✓ | ✗ | ✗ | ✗ |
| | **total** | **0/8** | **4/8** | **1/8** | **0/8** | **2/8** |

"no list" is the deletion wording, "inverted" the ported wording, "+ rule" the
typed list with the position rule. The kind-free version of the rule also
takes 2 of 8, but a different two — `13-09-46` and `15-36-12`. Four of the
eight resist every framing, and three of those four hold more than one
uncertain slot.

---

## Recommendation

Ship nothing. No arm clears the noise floor, and the two that move the
collision class each break a case the list exists to protect.

Measure the per-slot question next. Show the sentence once with a blank per
uncertain span, and under each blank only that span's candidates. That is the
only shape that can show the name where it is a candidate and hide it where it
is not — which is exactly what `10-12-37` needs and what a menu of whole
sentences cannot express. It also makes the cost linear in slots instead of
the product PR 6 had to cap at two.

Recorded as F17 in [vocabulary-v2.md](vocabulary-v2.md).
