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

---

# Round 2 — routing the case away from the judge

**The router loses. Do not build it.**

Round 1 said the judge fails one class because the term list must be present
for a name to be spellable and absent for a name to be doubted. Round 2 tested
the obvious repair: send each case to only one of them. If the decoded word is
not a real word, decide in code on the raw acoustic score. If it is a real
word, ask a judge one question about position, with no term list.

Both halves fail, and they fail for different reasons.

- **The code half cannot win, by construction.** `Vocabulary.autoApplies`
  already applies argmax on the raw score. A slot only reaches a menu when
  argmax said no. On all 8 not-a-word slots in the cache the decoded spelling
  scores at least as well as the term, and on all 8 the speaker meant the
  term. **Argmax scores 0/8.**
- **The judge half loses 7 to 15 cases.** The best position arm scores 32/51
  against the shipped prompt's 39/51 on the same subset.
- **Combined, the best arm is 32/53 against 41/53 today**, chance 17.4.

One thing did move, and it is about form, not about the question. Asking per
blank instead of per sentence takes the collision class from 3/8 to 6/8 at the
same wording, and wins exactly the three multi-slot clips a whole-sentence
menu cannot express. It loses too much elsewhere to ship.

Measured with `scripts/judge-routing.py` against `tests/judge-menus.json`,
`gemma4:e4b`, temperature 0, nothing else loaded. The shipped control was
re-measured in the same run at **41/53**, reproducing round 1 exactly. Three
full runs gave identical totals and identical per-case diffs. No reply lacked
a bare letter. No build, no install.

**The same 53 cases are tuned on and reported on.** There is no held-out set.
The second router below was chosen after looking at the first one's errors.

## What was tried

**Two wordings** of the position question, each in **two forms** — whole
sentence and one blank per slot. Four judge configurations, plus the shipped
prompt as control. **Two routers**: `Replacements.isRealWord` alone, and the
same with a capital mid-sentence overriding it.

## Recovering the slots

The cache stores whole sentences. `VocabularyJudge` composes them from a
cartesian product over uncertain spans and throws the combination away, so
`judge-routing.py` recovers the spans by diffing the options against each
other. The recovery is checked: the slot options must rebuild the menu
exactly, and they do for all 53. Five menus hold two adjacent spans that no
diff can separate; they come back as one wide slot with up to nine readings,
which is honest rather than convenient.

The decoded reading of a slot is the one carrying no vocabulary term.
`Replacements.isRealWord` is reproduced offline by `scripts/real-words.swift`
— the same NSSpellChecker call, lowercased, `en` then `fr` — and cached in
`tests/real-words.yaml`. **This reproduces the app's gate. It does not call
it.** A Python harness cannot link the app bundle.

## The split

77 uncertain slots over the 53 cases.

| slots | class | argmax raw score |
|---:|---|---|
| 8 | not a word, and scored | **0/8** |
| 5 | a dictionary word, capitalised mid-sentence | 5/5 |
| 27 | a dictionary word, lower case | 15/27 |
| 17 | a span of more than one word | 8/17 |
| 20 | no score line at all | cannot run |

Eight cases carry no score block whatsoever. Sixteen cases hold at least one
slot with no score line. Those cannot be routed by acoustic score under any
rule, so they belong to the judge whatever the design says.

By case, with `isRealWord` as the router: **2 go to code, 51 go to the
judge.** A case goes to code only when every one of its slots can.

## Branch B — why 0/8 is not bad luck

`Vocabulary.autoApplies` writes the term in when the term beats the decoded
word on the raw score **and** the decoded word is not a real word. So a slot
only reaches a menu when one of those two failed. On the not-a-word class the
second test passed, so the first must have failed: the decoded spelling scores
at least as well as the term. It does, on 8 of 8.

Argmax on that class can therefore only ever answer "keep what the decoder
wrote". It is not a weak signal — it is the residue of a decision the app
already took, and it is 0/8 because in all 8 the speaker meant the term.

```
17-38-44  "Pressy" -5.60    "Praisy" -5.78    said: praise the work that Praisy has done
17-26-56  "Versal." -8.24   "Vercel." -9.72   said: I changed settings in Vercel
17-05-32  "versal" -6.88    "Vercel" -7.70    said: the new Vercel deployment
14-11-21  "Superbase" -6.66 "Supabase" -6.78  said: Supabase is where the crawl data lives
14-11-21  "Versal" -6.11    "Vercel" -6.32    said: and Vercel hosts the dashboard
09-46-57  "Versal." -17.82  "Vercel." -18.67  said: deployed on Vercel
14-11-36  "Tasmine" -8.01   "Tasmeen" -8.75   said: Matthieu and Tasmeen
10-12-37  "Tasmin" -10.13   "Tasmeen" -10.68  said: that Tasmeen asked me to crawl
```

### Handing a constant back to the term

PR #68 took the vocabulary bonus out of the score block. Putting a constant
back is the smallest version of it, and it costs no model call.
`judge-routing.py --sweep`:

| offset | not a word | a dictionary word | more than one word |
|---|---|---|---|
| always keep the decoded word | 0/8 | **22/32** | **12/17** |
| 0.00 — the raw comparison | 0/8 | 20/32 | 8/17 |
| 0.75 | 5/8 | 14/32 | 5/17 |
| 1.50 | **8/8** | 13/32 | 3/17 |
| always write the term | **8/8** | 10/32 | 1/17 |

Read it as two facts. First, **the raw score adds nothing anywhere**: on the
dictionary-word class the constant policy "keep what was decoded" scores 22/32
and argmax scores 20/32, so the class label alone beats the number. Second,
the not-a-word column is unanimous — every slot in it was a term the speaker
meant — so it only reports how large a constant flips them, and **no offset
can fail there, because there is no counter-example in the cache**. That is a
gap in the data, not a result. It is why "always write the term on a non-word
slot" cannot be recommended from these 53 clips.

## Branch A — the question, and the form

51 cases, chance 16.4. `shipped` is today's prompt on the same subset.

| arm | branch A /51 | multi-slot /18 | combined /53 | collision /8 |
|---|---|---|---|---|
| shipped (control) | **39** | 12 | **39** | 0 |
| position, sentence | 24 | 4 | 24 | 3 |
| position wording 2, sentence | 32 | 6 | 32 | 4 |
| position, blank per slot | 31 | 7 | 31 | **6** |
| position wording 2, blank | 27 | 6 | 27 | **6** |

No router at all: **41/53**. Chance 17.4/53.

The two wordings differ by 8 cases in the sentence form and 4 in the blank
form. That is larger than F16's spread and larger than every difference
between the forms, so **the form is not the lever the totals turn on — the
wording is.**

The one place form does show is the collision class, where the same wording
goes 3/8 as a sentence and 6/8 as blanks. The three it gains are exactly the
multi-slot clips: `17-47-45`, `14-04-21`, `10-12-37`. Round 1 predicted this.
A whole-sentence menu carries every name in every option, so it cannot say
"this name yes, that name no". A blank can.

18 of the 51 branch-A cases hold more than one slot. On single-slot cases the
two forms are nearly the same question, and they score nearly the same.

### The position question, in full

Only the two marked paragraphs differ between the forms.

```
The user dictates text. The speech recogniser sometimes writes a proper name —
a person, a product, a brand — where the user said an ordinary English word.

So the only question is position. A name is not a verb: it cannot follow "to"
as an infinitive and it does not take -s or -ing the way a verb does. A name
does not modify a noun the way an adjective does. A name is not a preposition,
an article or a pronoun. Where the sentence needs an ordinary word to do its
work, an ordinary word is what the user said.

Sometimes the user is not dictating but teaching a correction — "urza spells
mirza", "Versal spells V E R C E L". The word before "spells" is the one they
want replaced later, so it has to survive now. Keep those readings as they are.

Below is the sentence, and every reading it might really have been.        <- form
Exactly one is what the user said.                                        <- form

Some come with a measure of how clearly the recogniser heard each spelling. A
gap under about 1 means the sound cannot tell them apart and the position has
to decide. A gap over about 4 means it can, and only a name standing where no
name can stand should overrule it.

Pick the reading in which every word stands where a word of its kind can   <- form
stand, unless the sound says otherwise by more than about 4. Answer with   <- form
its letter only.                                                          <- form
```

The blank form replaces those two paragraphs with:

```
Below is the sentence with one span left blank, and every reading that
span might be. Exactly one is what the user said.
```
```
Pick the reading that stands where a word of its kind can stand, unless
the sound says otherwise by more than about 4. Answer with its letter
only.
```

The second wording keeps everything except the second paragraph, which becomes:

```
A name can only stand where a name can stand: as a subject, as an object, or
after a preposition. It cannot be the verb of the sentence, it cannot be the
word an adjective would fill, and it cannot be an article or a pronoun. A name
put anywhere else leaves a sentence no native speaker would produce.
```

### What a blank question looks like — `10-12-37`

Two calls, one per slot. The other slot is shown as the decoder wrote it.

```
It's a community that ___ asked me to crawl.

A. Tasmeen
B. Tasmin

  "Tasmin" -10.13   "Tasmeen" -10.68   — "Tasmeen" heard 0.5 less clearly

Which letter?
```
```
It's a community that Tasmin asked me to ___

A. Redcrawl.
B. crawl.

  "crawl." -10.06   "Redcrawl." -11.83   — "Redcrawl." heard 1.8 less clearly

Which letter?
```

Round 1 named this clip as the one that argues for a per-slot question. Both
blank arms get it. Every whole-sentence arm in both rounds gets it wrong.

## The routing errors — 12 of 53

This is the real subject. `isRealWord` sends the wrong cases both ways.

**Sent to code, and code got it wrong — 2.** These two are the whole of
branch B.

```
17-26-56  said: I changed settings in Vercel
          Versal.  vs  Vercel.        the sound prefers Versal. by 1.5

09-46-57  said: The app is being deployed on Vercel.
          Versal.  vs  Vercel.        the sound prefers Versal. by 0.9
```

**Sent to the judge on a word nobody dictating could have meant — 10.** The
mangled name landed on a dictionary entry, so the gate called it an ordinary
word and handed it to a model.

```
16-09-50  Let's praise the work Praisy has done.        Prissy  vs Praisy
16-09-37  Let's praise the work Praisy has done.        Prissy  vs Praisy
16-09-15  Let's praise the work Praisy has done         Priss.y vs Praisy
16-09-00  Is Praisy here today?                         Prissy  vs Praisy
15-36-50  Let's praise the work that Praisy has done.   Prissy  vs Praisy
15-36-40  Praisy is here.                               Prissy  vs Praisy
15-21-19  Praisy did a great job.                       Prissy  vs Praisy
13-19-22  Praisy is with us today.                      Prissy  vs Praisy
14-11-48  Praisy sent me the Ollama benchmarks ...      Prissy  vs Praisy
15-21-29  Matthieu published a pull request.            Mathieu vs Matthieu
```

`Prissy` is in the English dictionary. `Mathieu` is in the French one, and the
app asks both. On every one of these ten, argmax would have been right without
a model. The gate is close to inverted on this cache: the two cases it sends
to code are the two it should not, and ten of the cases it protects from code
are the ones code would have settled.

## The second router — a capital mid-sentence

Chosen after seeing the list above, on the same 53 cases. If the decoded token
carries a capital and does not open a sentence, the decoder is saying it heard
a name, whatever the dictionary says.

It moves almost nothing. Branch B goes from 2 cases to **3**, and the new one
is right. Combined: shipped 39, best position arm 32. Misroutings fall from 12
to 11.

The reason is the case rule, not the test. Only 5 of the 27 offending slots
carry a mid-sentence capital — `Prissy is here.` and `Praisy did a great job.`
open their sentences, and the rest sit in cases whose other slot is a
multi-word span that can never go to code. A test that fires on a fifth of the
class it was built for is not the fix.

## Recommendation

**Do not build the router.** The design assumes the acoustic score is
informative where language is not. On these clips it is the reverse: argmax is
0/8 where the design trusts it and 20/32 where the design does not, and even
there a constant beats it.

Two things are worth carrying forward, both as evidence and neither as a
patch.

1. **The blank form is the right shape for multi-slot cases.** 3/8 to 6/8 on
   the collision class, and the three gained are the three that need per-slot
   expression. It costs one call per slot instead of one per case, which is
   linear instead of the product PR 6 capped at two. Measure it next with the
   *shipped* question rather than the position question, so form is separated
   from content the way it was not here.
2. **The cache has no non-word slot where the decoder was right.** Eight of
   eight went to the term. Until a clip exists where a non-word decoding is
   what the speaker said, no rule on that class can be falsified, and none
   should be shipped. That is a gap for `menu-cases.yaml` to fill.

Recorded as F18 in [vocabulary-v2.md](vocabulary-v2.md).

---

# Round 4 — is the score block informative?

**The acoustic evidence is decoration. Argmax on the raw score is 28/57
spans, and the constant "keep what the decoder wrote" is 34/57. A predictor
that loses to a constant carries no signal.**

Rounds 1-3 all rewrote the judge's question. The score block is the other half
of what the judge is given, and nobody had measured it. This round measures it
alone, with no model call anywhere: `scripts/gap-signal.py` is arithmetic over
`tests/judge-menus.json`.

53 reachable menus, **77 uncertain spans**. 57 carry a score line, 20 carry
none. Gaps run 0.01 to 2.72 nats and 40 of 57 are under 1 nat. **No span in
the cache reaches the shipped `decide_above: 3.0`** — the threshold the prompt
tells the judge about is one nothing crosses.

## Base rates — 57 scored spans

| policy | right | |
|---|---|---|
| argmax raw score | 28/57 | 49% |
| **keep what the decoder wrote** | **34/57** | **60%** |
| always write the vocabulary term | 23/57 | 40% |
| guess a reading at random | 23.9/57 | 42% |

Argmax beats a coin flip by 7 points and loses to doing nothing by 11. On 4 of
the 57 the score block names a winner the slot cannot act on — a merged span
whose readings all hold the same spelling, like `Praisy Mathieu's` against
`Praisy's Mathieu's`. Counting only the 53 it can decide, argmax is still
28/53.

Over all 77 spans, keeping what the decoder wrote is right 47/77.

## 1. Does the gap predict correctness?

Buckets 2-4 and 4+ are merged into 2+, because nothing exceeds 2.72.

| \|gap\| | spans | argmax right | keep decoded |
|---|---|---|---|
| 0 to 0.5 | 26 | 12/26 | 16/26 |
| 0.5 to 1 | 14 | 6/14 | 6/14 |
| 1 to 2 | 11 | 7/11 | 6/11 |
| 2+ | 6 | 3/6 | 6/6 |

**A 2-nat gap is no more reliable than a 0.1-nat gap.** The rate wanders
between 43% and 64% with no trend, over buckets of 26, 14, 11 and 6 spans. The
widest bucket is argmax's worst against the constant: 3/6 against 6/6. Six
spans is a count, not a rate — but it is the wrong sign, and it is the bucket
the prompt's "over about 4" language is trying to describe.

## 2. The absolute scores

Bucketed by the *better* of the two scores. The hypothesis was that everything
below about -8 is uninformative regardless of gap.

| better score | spans | argmax right | keep decoded |
|---|---|---|---|
| below -10 | 12 | 6/12 | 4/12 |
| -10 to -8 | 25 | 14/25 | 19/25 |
| -8 to -6 | 8 | 2/8 | 1/8 |
| -6 to -4 | 8 | 5/8 | 6/8 |
| above -4 | 4 | 1/4 | 4/4 |

**The hypothesis is not supported, and neither is its opposite.** Argmax's
worst bucket is -8 to -6, not the floor. 37 of the 57 spans sit below -8, so
most of the pass really is arguing about audio the recogniser barely resolved
— but the scores are no better higher up. Three of these five buckets hold
fewer than ten spans and cannot be read as rates.

The two together, to check for a corner where the score can be trusted:

| | spans | argmax right | keep decoded |
|---|---|---|---|
| gap under 1, heard above -8 | 15 | 6/15 | 6/15 |
| gap under 1, heard below -8 | 25 | 12/25 | 16/25 |
| gap 1 or more, heard above -8 | 5 | 2/5 | 5/5 |
| gap 1 or more, heard below -8 | 12 | 8/12 | 7/12 |

The one quarter where a threshold rule should work — a wide gap on clearly
heard audio — holds five spans and argmax gets 2 of them while the constant
gets 5.

## 3. Length

**The cache does not carry the bonus.** `Vocabulary.apply` subtracts it before
`VocabularyJudge.scoreBlock` writes the line, and `VocabularyRescorer.Config`
lives in FluidAudio, not in this repository. So the token count cannot be
recovered by inverting `adaptiveCbw`. **Character count of the spelling is used
as a crude stand-in and is labelled as one in every table below.** It is
monotone in token count for these spellings, which is all the comparison needs.

21 of 57 spans compare spellings of unequal length. Normalising flips the
winner on 8.

| score used | argmax right | |
|---|---|---|
| raw sum, as shipped | 28/57 | 49% |
| per character | 22/57 | 39% |

| per-character \|gap\| | spans | raw argmax | per-char argmax | keep decoded |
|---|---|---|---|---|
| 0 to 0.1 | 20 | 10/20 | 10/20 | 12/20 |
| 0.1 to 0.25 | 21 | 11/21 | 10/21 | 7/21 |
| 0.25 to 0.5 | 10 | 5/10 | 2/10 | 9/10 |
| 0.5+ | 6 | 2/6 | 0/6 | 6/6 |

**Normalising separates the classes worse.** It drops argmax from 28 to 22 and
turns the largest-gap bucket into an anti-predictor: 0/6, where the constant is
6/6. Length is not the confound.

## 4. The 20 spans with no score line

`scoreBlock` writes nothing for a proposal with no scores, and nothing for a
merged span that matches two score lines. On those 20 the judge sees the
readings and no evidence and has to decide on the sentence alone. Keeping what
the decoder wrote is right on 13 of the 20. 13 of the 20 sit in a case that
holds more than one span, so the judge cannot even tell which part of the
sentence the block is silent about.

## What the canonical clip looks like

Clip `00-14-39`, the `"general" -9.88` / `"Redcrawl" -9.97` pair that started
this. The gap is 0.09 and the speaker said `general`, so argmax happens to be
right. That is the shape of the whole cache: the answer is usually the decoded
word, and the 0.09 is not why.

## Recommendation

**Take the score block out of the judge's prompt and measure the judge without
it.** It is 57 lines of evidence that predict the answer worse than a constant,
and three rounds of prompt work have been tuned against a judge that reads
them; the prompt's "a gap under about 1" and "more than about 4" describe a
scale that does not exist in this data.

**The question is not the prompt and it is not the evidence — it is the menu.**
Rounds 1-3 changed the wording and the shape and moved nothing; round 4 shows
the numbers beside them are noise. What is left is the spotter: a menu only
exists where `Vocabulary.autoApplies` already declined, and 60% of the time the
right answer is the reading it declined to change. Measure how much is lost by
not building the menu at all before tuning anything else.

Measured with `scripts/gap-signal.py`. No model call, no build, no install. The
cache predates PR #70, so none of the 15 live collisions of 2026-08-08 are in
it.

---

# Round 5 — is the 110M CTC model the constraint?

**Unanswered, because the bigger model is broken. `parakeet-ctc-0.6b-coreml`
returns NaN on 64% of the frames under an uncertain span. It is not weaker
evidence than the 110M model — on 62 of 91 spans it is no evidence at all, so
there was never anything to compare. This rules out a model; it does not test
the hypothesis, and it is not evidence that model size does not help.**

Rounds 1-3 rewrote the judge's question and round 4 measured the evidence beside
it. This round asks about the thing that produces the evidence. The transcript is
written by `parakeet-tdt-0.6b-v3`, but the model that decides names — the one
`CtcKeywordSpotter` and `VocabularyRescorer` score against — is
`parakeet-ctc-110m`, five times smaller, chosen by the default argument of
`CtcModels.downloadAndLoad()`. Nobody had asked whether the default was right.

FluidAudio ships a bigger one. `PARROTFLOW_CTC_MODEL=110m|0.6b` now selects it,
defaulting to `110m`, so the A/B is a flag rather than two builds.

The five metrics were fixed before the run and are reported for both models.

| | metric | 110m | 0.6b | moved? |
|---|---|---|---|---|
| 1 | frames entirely NaN | **0/1378 (0%)** | **471/732 (64%)** | worse |
| 1 | spans with no usable frame | **0/144** | **62/91 (68%)** | worse |
| 1 | best-of-two score, median | **-8.50** | **-16.49** (finite only) | worse |
| 2 | argmax vs the constant | 33/66 vs **45/66** | 16/56 vs **39/56** | no |
| 3 | hit rate monotone in gap | no | not measurable | no |
| 4 | fixed / broken / regressed | 22 / 38 / 18 | **not measured** | — |
| 5 | recall / picked | 112/141 / 86/141 | **not measured** | — |

Metrics 4 and 5 were cancelled for 0.6b once metric 1 came back. They replay the
whole clip set three times through a model that returns no evidence on two
thirds of its frames, and the verdict rows would have measured the NaN, not the
model. The 110m columns were run and are kept, because they re-record the gate
baselines on the full set (below).

## 1. Confidence — the leading indicator

**It did not move toward zero. It stopped being a number.**

`PARROTFLOW_LOGPROB_DUMP`, ported from `spike/onset-pilot`, prints the top 8
non-blank tokens per frame under every span the pass proposed for. Over the 145
labelled clips:

| | 110m | 0.6b |
|---|---|---|
| spans dumped | 144 | 91 |
| frames under them | 1378 | 732 |
| frames where all 1024 tokens are NaN | **0** | **471 (64.3%)** |
| spans with no usable frame at all | **0** | **62** |

The NaN is not an edge artefact. The median NaN frame sits at 2.45s and the
median usable frame at 6.94s, so it is spread through the clip.

On the 29 spans that still produce numbers the distribution has collapsed rather
than sharpened. Frame 44 of clip `17-47-45`, under "retry":

    110m   f44   ▁in -6.35   , -6.90   . -7.34   ▁is -8.10  …
    0.6b   f44   ross -0.01  _T -4.57   _hundred -7.33  th -8.27  …

`ross -0.01` is near-certainty on a token nothing said. So the naive reading of
this metric — best non-blank log-prob improved from -2.50 to -0.00 — is an
artefact of that collapse. The median frame did not improve: -4.71 against
-5.08.

The scores the pass decides on moved the same way. **0 of 85 score lines
saturate under 110m; 53 of 72 (74%) saturate under 0.6b** at multiples of
`-FLT_MAX`, which is NaN carried through the rescorer's sum. The 19 finite ones
have a median of -16.49 against 110m's -8.50.

## 2. Does the score beat the constant?

**No, under either model, and 0.6b is much further from it.**

| cache | reachable | spans | scored | argmax | keep decoded |
|---|---|---|---|---|---|
| committed cache (round 4) | 53 | 77 | 57 | 28/57 (49%) | **34/57 (60%)** |
| fresh 110m harvest | 60 | 88 | 66 | 33/66 (50%) | **45/66 (68%)** |
| fresh 0.6b harvest | 57 | 76 | 56 | 16/56 (29%) | **39/56 (70%)** |

The first row reproduces round 4 exactly from the committed cache, which is how
the harness was checked before the comparison was trusted. **The 110m row is the
one the 0.6b row must be read against**: both fresh caches cover the 145 clips
of `tests/menu-cases.yaml`, while the committed cache covers 130 and predates
PR #70. Re-harvesting moved the constant from 60% to 68%, so the round-4
baseline is superseded for this set.

Argmax under 0.6b is 29%, below the 41% of guessing a reading at random.

## 3. Is the gap predictive?

**Not measurable under 0.6b, and still not monotone under 110m.**

Only 10 of 56 scored spans under 0.6b have a finite gap; the rest are
differences between two sentinels and run to 2.6e38 nats. 47 of 56 "reach" the
shipped `decide_above: 3.0`, which is the sentinel and not evidence. Ten spans
over four buckets is a count, not a rate.

Under the fresh 110m cache round 4's finding stands: 14/31, 6/12, 9/14, 4/9. No
trend, and the widest bucket is argmax's worst against the constant.

## Comparability — the spans both caches hold

Changing the model changes which spans reach a menu, so the two runs above score
different sets. Restricted to the **64 spans present in both**:

| | spans | scored | argmax | keep decoded |
|---|---|---|---|---|
| 110m (shared) | 64 | 54 | **31/54 (57%)** | 38/54 (70%) |
| 0.6b (shared) | 64 | 51 | **15/51 (29%)** | 38/51 (75%) |

24 spans are 110m-only and 12 are 0.6b-only. **The intersection agrees with the
full sets.** On the 26 shared spans where the two models disagree, 110m is right
on 21 and 0.6b on 5.

## The costs

| | 110m | 0.6b |
|---|---|---|
| on disk | **99 MB** | **2.2 GB** (22x) |
| first-run download | seconds | ~8 minutes |
| model load, warm | 0.16-0.25s | 0.14-0.16s |

The per-dictation latency delta was not measured. It was cancelled with metrics
4 and 5: timing a model that returns NaN on most frames prices work nobody would
ship. Load time is from the smoke runs and is not the number that would matter.

## What is broken, and what is not

It is **not** a tokenizer mismatch. Both `tokenizer.json` files use the
SentencePiece `▁` boundary with the same ids — `▁are` is 111 in both — so
`CtcTokenizer.encode` returns identical sequences for every term. The terms
tokenise and the spans line up. The `vocab.json` files differ cosmetically, and
that table only names ids in the dump.

It is the encoder output, and FluidAudio says so itself in
`CtcModels.swift:7-11`:

    /// - ctc110m: Blank-dominant (CTC head is auxiliary loss), greedy produces ~113% WER
    /// - ctc06b: CoreML conversion issue causes greedy to produce ~158% WER (should be ~14%)
    ///
    /// Recommended approach: Use TDT for transcription + CTC for vocabulary scoring
    /// via constrained CTC rescoring.

That last line is the path this pass already uses, which is exactly why the
model was worth testing rather than dismissed on the warning. Measured, the
conversion damage is not confined to greedy decoding: it reaches the per-frame
log-probs the constrained path reads, as NaN.

## What this settled, and what it did not

**Settled: `parakeet-ctc-0.6b-coreml` is unusable as exported.** NaN on 471 of
732 frames, 62 of 91 spans with no usable frame at all, 53 of 72 score lines
saturated at multiples of `-FLT_MAX`. That is a fact about the export, and it is
enough to keep the model out of the app.

**Not settled: whether weak acoustic evidence is the binding constraint on the
vocabulary pass.** That question is still open, because the larger model never
produced usable evidence to compare against. Nothing here is evidence that CTC
model size does not help. A broken export is not a null result, and it must not
be filed as one.

## Recommendation

**Do not ship `parakeet-ctc-0.6b`, and do not read this as closing the
model-size question.** The flag and both harnesses stay, so re-measuring is one
command per model.

**What would unblock the original question:** a working 0.6B CTC export, or the
hybrid `parakeetTdtCtc110m` (`ModelNames.swift:55`) which is a third variant
nothing here has tried, or reporting the NaN upstream to FluidInference and
waiting for a re-export.

**Meanwhile the next move is still the menu, not the model.** Round 4 asked what
is lost by not building the menu at all. Nothing here changes that, and the
re-harvest below makes the case stronger than round 4 could.

## A correction to round 4, found on the way

**On the better set the acoustic score is further behind the constant than
round 4 reported, not closer.**

Round 4 ran against the committed cache: 130 clips, harvested before PR #70. The
110m re-harvest here covers the 145 of `tests/menu-cases.yaml`, block 3
included. Same model, same code, larger set:

| | round 4 (130 clips) | re-harvest (145 clips) |
|---|---|---|
| scored spans | 57 | 66 |
| argmax raw score | 28/57 (49%) | 33/66 (50%) |
| **keep what the decoder wrote** | **34/57 (60%)** | **45/66 (68%)** |
| argmax's deficit | 11 points | **18 points** |

Argmax stayed at chance. The constant gained 8 points. So the gap round 4 called
"a predictor that loses to a constant" is wider on the fuller set, and round 4's
conclusion is strengthened rather than qualified. **Quote the re-harvest row,
not the committed one**, for anything measured against this set.

The gate baselines were re-recorded on the same 145 clips at the same time, and
they move too:

| | documented (127 clips) | re-recorded (141 labelled) |
|---|---|---|
| `before-after.py --runs 3` | 20 fixed / 26 broken / 11 regressed / 70 kept | **22 / 38 / 18 / 63** |
| `menu-recall.py --runs 3` | recall 102/127, picked 90/127 | **recall 112/141, picked 86/141** |

Recall holds (80.3% → 79.4%) but picked falls (70.9% → 61.0%) and regressions
rise (8.7% → 12.8%). Block 3 is harder than the set the floors were set on, so
**the floors in the plan are floors for a set that no longer exists.** 2 clips
flipped between runs in each harness (F12a).

Measured against FluidAudio 0.15.5, `gemma4:e4b`, temperature 0, nothing else
loaded, on the 145 labelled clips of `tests/menu-cases.yaml`. Build only, never
installed.

Recorded as F19 in [vocabulary-v2.md](vocabulary-v2.md). Full write-up in
[ctc-06b-report.md](ctc-06b-report.md).
