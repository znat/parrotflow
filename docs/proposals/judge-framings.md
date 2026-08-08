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
