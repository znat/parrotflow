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

# Round 5 — the raw score with the bonus switched off

**It cannot reject a wrong term. With the vocabulary bonus at zero, a term the
speaker did not say scores *higher* than a term they did — AUC 0.318 — and a
term they did say is indistinguishable from a term that is not in the sentence
at all — AUC 0.454 against the noise floor, where 0.5 is a coin.**

**One number here is still worth acting on, and it is a floor rather than a
rule.** The two paths behave differently and only one carries a gap. On the
rescorer path nothing separates, on any statistic. On the spotter path its own
score separates well enough that today's `spotterFloor` of -5.0 is too low:
-4.25 removes 28 of 92 wrong proposals and loses none of the 39 right ones. It
is a loudness gate, it fixes one clip of the collision class out of eight, and
it needs a per-case measurement before anyone moves it. It has its own section
below.

Round 4 measured the score block the judge is shown and found it worthless. The
obvious objection was that the block is contaminated: the rescorer decides on
the boosted score, so the numbers reaching a menu are the residue of a decision
the bonus already took. Round 5 removes the bonus and asks the question again on
the raw number, over all 145 clips of `tests/menu-cases.yaml` rather than the 53
cached menus.

Measured with `scripts/raw-score-separation.py` against
`tests/raw-score-separation.json`. No judge, no Ollama, no menu, no model call
anywhere: the sweep runs with a scratch `PARROTFLOW_CONFIG_DIR` whose pipeline
has no `vocabulary:` stage. Build only, no install. The per-proposal data is in
[raw-score-separation.md](raw-score-separation.md).

## What was built

`PARROTFLOW_CBW` overrides the vocabulary bonus. Unset it is FluidAudio's
`cbw: 4.5` and nothing changes for the user; set to 0 the rescorer compares raw
score against raw score.

**That is a different pass, not a quieter one.** `shouldReplace` is FluidAudio's
and it is computed on the boosted score —
`VocabularyRescorer+TokenEvaluation.swift:109-113`. At cbw 0 the test becomes
`rawVocabScore > originalCtcScore`, so a candidate only surfaces where the audio
already preferred the term. **Which candidates exist at all changes, and the
count is itself a result.**

| | rescorer | applied | proposed | dropped | spotter | wider | total |
|---|---|---|---|---|---|---|---|
| today, cbw 4.5 | 111 | 14 | 95 | 2 | 33 | 195 | **339** |
| cbw 0 | 59 | 18 | 41 | 0 | 41 | 101 | **201** |

Rescorer proposals nearly halve. Two things move the other way and both follow
from the same test. More proposals auto-apply (14 → 18), because at cbw 0 a
surviving candidate has already beaten the decoded word on the raw score, which
is half of what `autoApplies` asks. And the spotter path finds more (33 → 41),
because it only takes spans the rescorer did not claim.

`PARROTFLOW_SPOTTER_DUMP` now also writes one machine-readable line per
proposal — kind, verdict, the decoded word and its score, the term and its
score, the gap, the word indices and the seconds — on the same axis as the
`word` and `spotter:` lines it already wrote. That is the whole mechanism; no
second one was added.

*Nothing changed for the user.* With `PARROTFLOW_CBW` unset the override is the
old expression, and every dump line is behind the env var. Checked rather than
argued: three clips through the installed `78d7ba2` and through this branch's
build, same scratch config, same `vocabulary:` lines on two of the three. The
third differed, and five replays per binary show why — the *installed* binary
produces both readings of `Superbase` → `Supabase` on the same file, four
`proposed` and one `applied`, with the raw score moving 2.7 nats. That is F12a,
not the change.

*No model was called.* The scratch config has no `vocabulary:` stage and
`llm.enabled: false`. An Ollama server was running on the machine for unrelated
work and was left alone; nothing in this round can reach it.

## The three groups

Over every proposal the pass makes:

- **A — the term was said.** The label puts the term at this span.
- **B — the term was NOT said.** The label puts an ordinary word there. These
  are the failures.
- **C — random terms.** Every other vocabulary term the spotter scored over the
  same span, restricted to terms that appear nowhere in that clip's label. This
  is what a gap looks like when the term is definitely absent.

**The rule for A against B.** The decoder's words are aligned to the label's
words with `difflib`. A proposal covers decoded words *i..j*. Every covered word
inside an `equal` block means the label kept what the decoder wrote, so the
speaker said the ordinary word: **B**. Inside a `replace` block, only the label
words that block puts *at that position* are read — a term somewhere else in the
sentence is not a term belonging at this span. The term in the aligned window is
**A**, the term nowhere in the block is **B**, and the term in the block but at
another position with the block too long to pin is **unclear**.

**Unclear is 2 of 101 at cbw 0 and 4 of 135 today, and every one of them is a
clip with no `said:` label at all.** No proposal was forced into a group by an
alignment nobody could check.

**The statistic is the spotter's raw score for the term over the span, in nats
per token.** It has to be one number on one scale for all three groups, and
group C has no decoded-word score to subtract because nothing ever proposed
those terms. Both numbers come out of the same dynamic program,
`CtcDPAlgorithm`, normalised by the term's token count; the rescorer scores over
a window it is given and the spotter finds its own, and that difference in
window is the one seam in the comparison. The rescorer's gap — the number the
judge is actually shown — is reported beside it for the two groups that have
one.

## The distributions, cbw 0

101 distinct proposals over 63 clips, each the median of the replays it appeared
in. A 33, B 66, unclear 2.

| group | n | min | q1 | median | q3 | max |
|---|---:|---:|---:|---:|---:|---:|
| A term was said | 33 | -12.27 | -10.49 | **-6.81** | -5.04 | -2.28 |
| B term was NOT said | 66 | -11.58 | -6.45 | **-4.88** | -4.58 | -2.51 |
| C random terms | 917 | -14.04 | -9.07 | **-7.10** | -6.40 | -4.23 |

Counts per nat, each column scaled to its own tallest bar:

```
        A (33)                  B (66)                  C (917)
 -13 |#                      |                       |###
 -12 |####                   |#                      |###########
 -11 |#####                  |#####                  |#########
 -10 |##                     |##                     |########
  -9 |##                     |###                    |#########
  -8 |##                     |##                     |#########################
  -7 |##                     |########               |########################################
  -6 |########               |###                    |#################
  -5 |###                    |####################################|  #
  -4 |####                   |#####                  |
  -3 |#                      |#                      |
```

**B sits above A, not apart from it.** The median of a wrongly proposed term is
1.9 nats *better* than the median of a correctly proposed one.

## Overlap — the whole question

| | share |
|---|---|
| B inside A's range | **100%** |
| B inside C's range | **88%** |
| A inside C's range | 85% |

Every wrong proposal falls inside the range of the right ones. Nearly nine in
ten fall inside the range of terms that are definitely not in the sentence.

## Separability

AUC of the score telling one group from another. 0.5 is a coin. Above 0.5 means
the first group scores higher.

| | cbw 0 | today |
|---|---|---|
| AUC(A vs B), all proposals | **0.318** | 0.379 |
| AUC(A vs C), all proposals | 0.570 | 0.587 |
| AUC(B vs C), all proposals | 0.811 | 0.732 |
| AUC(A vs B), **rescorer only** | 0.425 | 0.459 |
| AUC(A vs C), **rescorer only** | **0.454** | 0.540 |
| AUC(B vs C), **rescorer only** | 0.526 | 0.589 |
| AUC(A vs B), the rescorer's gap | 0.593 | 0.668 |

Read the rescorer rows, not the "all" rows. Spotter-path proposals only exist
above `spotterFloor` at -5.0 while group C is almost entirely below it, so their
AUC(A vs C) of 0.999 is the floor reporting itself. It is not a signal: B scores
0.997 against C on the same rows, which says the floor selects loud spans and
not correct ones.

**On the rescorer's own proposals, with the bonus off, a term that was said is
at chance against a term that is not in the sentence: 0.454, with 100% of A
inside C's range.** A term that was *not* said does no worse, at 0.526. The
score is not identifying anything specific, so there is nothing to reject on.

The gap — raw term minus raw decoded word — is the only column above chance, and
it is thin. At cbw 0 it is 0.593, A median 1.00 against B median 0.51, with 73%
of B inside A's range. And it is truncated by construction: at cbw 0 nothing
surfaces unless the gap is already positive, so 30 A and 30 B all sit between
0.01 and 2.44.

**A threshold cannot beat a constant.** Fitted and scored on the same rows,
which is the most flattering number available:

| | best cut | always say the bigger group |
|---|---|---|
| spotter score, rescorer proposals | 31/52 (60%) | 26/52 (50%) |
| the rescorer's gap | 38/60 (63%) | 30/60 (50%) |

Five to six cases of in-sample gain on about sixty, with no held-out set. That
is round 4's finding again on the raw number: a predictor that barely beats a
constant when it is allowed to see the answer carries no signal.

## The two paths are not the same, and one of them has a usable floor

The AUCs above are computed per path for a reason. **A proposal reaches a menu
two ways, and only one of them carries a gap.**

- The **rescorer** matches spelling and scores both the decoded word and the
  term. It has a gap. At cbw 0, 54 of the 101 scored proposals are its.
- The **spotter** replaces a span because the CTC search heard the term there.
  It has no decoded-word score and never had one — `Vocabulary.apply` writes
  `heardScore: nil` because the spotter scored the term, not the word standing
  there. It makes the other 47, and **it is where most failures live: 40 of the
  66 B at cbw 0, 32 of the 92 today.**

So the gap AUC never saw the majority of the failures. Asked separately:

| statistic | path | A n | B n | AUC(A vs B) |
|---|---|---:|---:|---|
| the gap | rescorer | 30 | 30 | 0.593 |
| raw term score, per token | rescorer | 30 | 30 | **0.487** |
| spotter score at the span | rescorer | 26 | 26 | 0.425 |
| spotter score at the span | spotter | 7 | 40 | **0.814** |

At today's cbw the same two rows are 0.457 and 0.945.

**Per-token normalisation is not doing the work.** The `spot` column is
normalised by the term's token count and the gap is not, so the fourth question
was whether that alone explains the difference. It does not: the rescorer's own
raw term score is per token and needs no subtraction, and it scores **0.487** —
a coin. On the rescorer path nothing separates, on any of the three statistics.

### The floor

The spotter path already gates on its own score. `Vocabulary.spotterFloor` is
-5.0 and it admits every B in the table. Moving it, on the spotter path's 47
proposals at cbw 0:

| floor | A kept | B kept | B cut | A cut |
|---|---|---|---:|---:|
| **-5.00** (today) | 7/7 | 40/40 | 0 | 0 |
| -4.75 | 6/7 | 24/40 | 16 | 1 |
| -4.50 | 6/7 | 14/40 | 26 | 1 |
| **-4.25** | **6/7** | **7/40** | **33** | **1** |
| -4.00 | 5/7 | 5/40 | 35 | 2 |
| -3.75 | 3/7 | 3/40 | 37 | 4 |
| -3.50 | 3/7 | 1/40 | 39 | 4 |

At today's cbw, where the shipped app lives, it is better: **-4.25 keeps 4 of 4
right and cuts 28 of 32 wrong.**

Both paths together, since a case is decided by every proposal on it:

| | A kept | B kept |
|---|---|---|
| cbw 0, floor -4.25 | 32/33 | 33/66 |
| **today, floor -4.25** | **39/39** | **64/92** |

At today's setting nothing correct is lost and 28 wrong readings never reach a
menu. The one right proposal lost at cbw 0 is `Praisy` over "Pressy" at -4.94 on
`17-38-44`, and it is that clip's only proposal — so the clip loses its reading
entirely. At today's cbw the rescorer also proposes there and the clip survives.

Below -5.0 these runs have no data. `acousticSpans` drops a detection under the
floor before anything logs it, so a lower floor admits spans this sweep never
scored. -5.5 and -5.25 would need their own runs.

### Why this is a smaller finding than it looks

**It is a loudness gate, not a rejection rule.** The same rows give
AUC(A vs C) = 0.999 *and* AUC(B vs C) = 0.997: the spotter score separates
"something is here" from "nothing is here", and does that almost perfectly. It
does not separate "the right thing is here" from "the wrong thing is here". What
a higher floor removes is the quiet bulk. What it cannot remove is a wrong
proposal that is loud — and those are the ones that cost cases.

The top of the distribution says it in two lines. The best-scoring proposal in
the whole set is `Vercel` over "Versailles" at **-2.28**, correct. The second
best is `Vercel` over "universal" at **-2.51**, wrong, **in the same clip**. No
floor separates those two.

**It fixes one clip of the collision class.** Of the eight clips PR #68 recorded
as regressed, only three carry a spotter-path proposal at all, and a -4.25 floor
removes all three: `14-04-21`, `14-09-56`, `11-19-17`. Only `11-19-17`
("proprietary" → `Praisy`) is actually fixed by it, because it is the clip's
only proposal. The other two still carry a rescorer-path wrong reading the floor
cannot touch — `crawl` → `Redcrawl` and `matches` → `Matthieu`. **Seven of the
eight fail on the path where nothing separates.**

**And it is in-sample.** 47 spotter proposals, fitted and scored on the same
rows, no held-out set. The floor's existing sweep in `Vocabulary.spotterFloor`
was run on `menu-recall.py` per *case* and stopped at -4.8 with a plateau from
-5.0; -4.25 is outside what that measured. Proposal counts are not recall, and
`spotterFloor` also gates `spottedAnything`, which decides whether the pass
produces anything at all on a clip where the rescorer found nothing. Raising it
can silence a whole clip. **Nobody should move this number without running
`menu-recall.py --runs 3` across the range.**

## Per term

The ablation found `Redcrawl`, `Supabase` and `Ollama` with 0 wins and 9 losses
between them. Their gaps do not look different. cbw 0, spotter score at the
span:

| term | A n | A med | B n | B med | C n | C med | AUC A/B | AUC A/C | AUC B/C |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Arexvy | 0 | — | 1 | -9.55 | 91 | -7.25 | — | — | 0.23 |
| Claude | 0 | — | 5 | -4.73 | 90 | -6.93 | — | — | 0.83 |
| Matthieu | 3 | -5.81 | 3 | -4.98 | 88 | -7.30 | 0.33 | 0.85 | 0.79 |
| Mirza | 0 | — | 4 | -5.28 | 79 | -6.67 | — | — | 0.77 |
| Ollama | 1 | -11.99 | 2 | **-4.57** | 88 | -6.83 | 0.00 | 0.01 | **1.00** |
| Praisy | 21 | -8.00 | 37 | -4.84 | 41 | -6.40 | 0.32 | 0.47 | 0.77 |
| Redcrawl | 0 | — | 3 | -6.15 | 96 | -6.79 | — | — | 0.70 |
| Redrock | 0 | — | 1 | -6.98 | 84 | -7.78 | — | — | 0.86 |
| Supabase | 1 | -4.94 | 2 | -7.43 | 89 | -7.78 | 0.50 | 1.00 | 0.56 |
| Tasmeen | 1 | -11.35 | 3 | -4.89 | 94 | -6.70 | 0.00 | 0.05 | 0.99 |
| Vercel | 6 | -5.80 | 5 | -4.83 | 77 | -7.05 | 0.37 | 0.72 | 0.83 |

Three things, and none of them is a difference between those three terms and the
other two.

**The three terms have almost no A cases in this set.** `Redcrawl` 0 of 3,
`Supabase` 1 of 3, `Ollama` 1 of 3. Nothing here can say whether their gaps look
different from `Praisy`'s when they are right, because they are almost never
right.

**Their wrong proposals are not quiet.** `Ollama`'s B median is -4.57 and
`Praisy`'s A median is -8.00: the wrong `Ollama` is heard 3.4 nats more clearly
than the average correct `Praisy`. `Redcrawl`'s B median of -6.15 sits 0.64 nats
above its own noise floor of -6.79, which is not a distance a rule can act on.

**The last column is the damning one.** AUC(B vs C) is 1.00 for `Ollama`, 0.99
for `Tasmeen`, 0.83 for `Claude` and `Vercel`. For those names the score does
not merely fail to reject a wrong proposal — it endorses it, ranking the wrong
term above every term that is genuinely absent.

`Praisy` is the exception that explains the mechanism. Its AUC(A vs C) is 0.47:
a correct `Praisy` is at chance against a `Praisy` scored over a span where it
was never spoken. It carries fourteen registered renderings, so every span in
every clip gets fourteen draws for that name and the best of fourteen is high
everywhere. That is the effect `Vocabulary.spotterFloor` documents, measured
here as an AUC.

## Run to run — F12a

Every clip was replayed three times in each condition, 870 replays in all.

| condition | quantity | n | median spread | q3 | max | over 1 nat |
|---|---|---:|---:|---:|---:|---:|
| cbw 0 | gap | 57 | 0.00 | 0.01 | 0.67 | 0% |
| cbw 0 | spotter score | 87 | 0.00 | 0.00 | 1.70 | 2% |
| cbw 0 | term score | 94 | 0.00 | 0.00 | **5.70** | 5% |
| today | gap | 111 | 0.00 | 0.01 | 2.40 | 3% |
| today | spotter score | 127 | 0.00 | 0.00 | 3.11 | 3% |
| today | term score | 140 | 0.00 | 0.00 | **8.12** | 4% |

Most replays are exact. **The tail is not, and the tail is larger than the
effect.** About one proposal in twenty moves more than a nat between replays,
and the worst moves 5.7 nats at cbw 0 and 8.1 today — against an A-versus-B
separation of 0.49 nats on the gap and 1.9 nats on the spotter score, the latter
in the wrong direction. On top of that, **13 of 107 proposals at cbw 0 and 8 of
148 today do not appear in all three runs at all**: the same audio, replayed,
proposes a different thing.

So the settled part of the answer does not need the AUCs. For the fifth of
proposals where a threshold would have to be close, the number moves further
between two replays of the same file than the two classes are apart.

## Recommendation

**Do not build a rejection rule on the acoustic score, at any bonus.** Round 4
showed the score block does not predict the answer; round 5 shows the number
underneath it does not identify the term either. A wrongly proposed term looks
exactly like a randomly chosen one, and often better than a correct one. On the
rescorer path — the majority of proposals — all three statistics tried are at
chance: the gap 0.593, the raw term score per token 0.487, the spotter score
0.425.

**The bonus is not the bug, and taking it out costs recall.** At cbw 0 the
rescorer makes 59 proposals instead of 111, and the ones it drops are not the
wrong ones — the same two-to-one mix of failures to successes survives. Keep
`cbw` where it is. `PARROTFLOW_CBW` stays as a measurement tool, defaulting to
today's value.

**One thing here is worth acting on, and it is a floor rather than a rule.**
`Vocabulary.spotterFloor` is -5.0 and admits every wrong spotter-path proposal
in this set. At -4.25 the whole set goes from 39 right and 92 wrong to 39 right
and 64 wrong: 28 wrong readings never reach a menu and nothing correct is lost.
That is a menu-size lever, not a fix — it is a loudness gate, it fixes one clip
of the collision class out of eight, and the two highest-scoring proposals in
the whole set are a correct `Vercel` at -2.28 and a wrong `Vercel` at -2.51 in
the same clip. **Measure it with `menu-recall.py --runs 3` per case before
moving it**, because proposal counts are not recall and the same number gates
whether the pass produces anything at all.

The rest of what is left to measure is what round 4 pointed at. The only
rescorer-path column above chance is the *gap* against the decoded word, at AUC
0.59-0.67 — weak, but it is the only number that knows what else was on the
audio. Every absolute level is at chance except as a presence test. If anything
acoustic is worth another attempt it is a comparison, never a level.

Recorded as F19 in [vocabulary-v2.md](vocabulary-v2.md).
