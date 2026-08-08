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

# Round 3 — the same question, in blanks

**The blanks lose. Do not change the shape.**

Round 2 credited the blank form with 3 cases on the collision class, but it
changed the wording and the shape at once. Round 3 changes only the shape. The
shipped prompt, the shipped vocabulary list and the shipped score block go into
both arms. One states the sentence once per reading. The other states it once,
with a numbered blank per uncertain span and the candidates under each number.

| arm | total /53 | multi-slot /18 | single-slot /35 | collision /8 |
|---|---|---|---|---|
| sentence — what ships today | **41** | **12** | **29** | 0 |
| blank | 37 | 9 | 28 | **3** |
| chance | 17.4 | 2.8 | 14.6 | 2.1 |

The blank form wins the collision class and loses the total. **It wins 4 cases
and loses 8.** Round 2's 6/8 does not survive: with the shipped question the
blanks reach 3/8, and 2 of the 3 are single-slot clips, where the two arms ask
nearly the same question. **So the shape is worth about half of what round 2
credited it with. The other half was the wording.**

And the collision class is a fixed list of 8 clips, which hides the real
result. Counted over all 77 uncertain spans, **the blank form does not fix the
failure. It moves it.**

| | collision clips, 16 spans | every other clip, 61 spans |
|---|---|---|
| sentence | 4 right, **12 overwrites** | 57 right, **3 overwrites**, 1 name lost |
| blank | 10 right, **6 overwrites** | 49 right, **8 overwrites**, 4 names lost |

An *overwrite* is the error the whole spike is about: the speaker said an
ordinary word and the arm wrote a name over it. On the 8 clips PR #68 named,
the blanks halve them. On the other 45 clips they more than double them. Over
all 77 spans the overwrite count barely moves — 15 against 14 — and the blanks
lose 4 names where the sentence loses 1.

And 37/53 is not a score the blank form owns. A blank must letter its own
candidates, and that choice carries no information. Sorting them instead of
keeping the app's order takes the arm to **31/53** and the overwrites to 20.
**Letter order moves it 6 cases; the shape moves it 4.**

Measured with `scripts/judge-blanks.py` against `tests/judge-menus.json`,
`gemma4:e4b`, temperature 0, nothing else loaded. The control re-measured at
41/53, reproducing rounds 1 and 2 exactly. Three full runs gave identical
totals and identical per-case diffs. No reply was unreadable. No build, no
install.

**The same 53 cases are tuned on and reported on.** There is no held-out set.

## The one variable

Three sentences of `verify_names.md` describe the shape of the question and of
the answer. Those three change and nothing else does. They are quoted in
`BLANK_EDITS` and the run fails loudly if one stops matching the prompt file.

```diff
-A name matcher was unsure about some words. Below is the sentence, and every
-reading it might really have been. Exactly one is what the user said.
+A name matcher was unsure about some words. Below is the sentence with each of
+them blanked and numbered, and every reading each blank might really have been.
+Exactly one reading of each blank is what the user said.
```
```diff
-Pick the reading that makes sense as a sentence, unless the sound says
-otherwise by more than about 4. Answer with its letter only.
+Pick the reading of each blank that makes sense as a sentence, unless the sound
+says otherwise by more than about 4. Answer with one letter per blank and
+nothing else, like "1=A 2=B".
```

The user message ends `Which letter for each blank?` instead of the app's
`Which letter?`. One string for every case, so a one-blank case and a
three-blank case are asked in the same words.

Everything else is identical: the vocabulary list, the paragraph about
"spells", the paragraph about the acoustic gap, the "makes sense as a sentence"
test, and the score block, which goes in unchanged because it names spellings
and not slots. Chance is the same number for both arms, because the slot
readings multiply back out to the menu — the harness refuses to run a case
where they do not.

Only 14 of the 53 replies used `1=A 2=B`. 29 were a single letter for a single
blank, read by the app's own rule. 10 were bare letters in order — `A B` for
two blanks. **Nothing was unreadable**, so the losses below are answers, not
formatting.

## What a blank question looks like — `10-12-37`

The clip round 1 named as the one that argues for a per-slot question. The
score block is the same text in both arms.

```
It's a community that ___1___ asked me to ___2___

1. A. Tasmin
   B. Tasmeen

2. A. crawl.
   B. Redcrawl.

  "Tasmin" -10.13   "Tasmeen" -10.68   — "Tasmeen" heard 0.5 less clearly
  "crawl." -10.06   "Redcrawl." -11.83   — "Redcrawl." heard 1.8 less clearly

Which letter for each blank?
```

The blank arm gets it. The sentence arm takes `Tasmeen … Redcrawl`, and has in
every framing of every round. One name is right and one is wrong, and a menu of
whole sentences carries both in every option.

## The collision class

| clip | spans | said → written | sentence | blank |
|---|---:|---|---|---|
| `17-47-45` | 3 | retry/crawl → Arexvy/Redcrawl | ✗ | ✗ |
| `09-35-01` | | Versailles → Vercel castle | never reached a menu ||
| `14-04-21` | 3 | explanations to update → Praisy to Supabase | ✗ | ✗ |
| `10-12-37` | 2 | asked me to crawl → to Redcrawl | ✗ | **✓** |
| `14-09-56` | 2 | near matches → near Matthieu | ✗ | ✗ |
| `13-09-46` | 1 | praise for shipping → Praisy shipping | ✗ | ✗ |
| `11-19-17` | 1 | proprietary term → Praisy term | ✗ | **✓** |
| `15-36-12` | 1 | Pretty harsh → Arexvy harsh | ✗ | **✓** |
| `14-11-21` | 3 | the crawl data → the Redcrawl data | ✗ | ✗ |
| | | **total** | **0/8** | **3/8** |

The shipped prompt is 0/8 for the fourth round running. The blanks take 3.
Only one of the 3 is the multi-slot case the shape was designed for. The other
two are one-span clips — `Chain is a langsmith ___ term.` and `___ harsh
review.` — where the two arms differ only in that the blank arm prints the
sentence once instead of twice.

## The trade, per span

A case counts only when every one of its spans is right, so a three-span case
scores zero whether it missed one span or three. `17-47-45` is the example: the
sentence arm gets none of its three spans, the blank arm gets two, and both
score ✗. Per span is where the trade is legible.

77 spans over the 53 cases. Two ways to be wrong, and they are not the same
mistake.

| arm | right | wrote a name over an ordinary word | kept what was decoded, losing the name |
|---|---|---|---|
| sentence | **61/77** | 15 | **1** |
| blank | 59/77 | **14** | 4 |

Split by whether the clip is in PR #68's list:

| | collision clips, 16 spans | every other clip, 61 spans |
|---|---|---|
| sentence | 4 right, 12 overwrites, 0 names lost | 57 right, 3 overwrites, 1 name lost |
| blank | **10 right**, **6 overwrites**, 0 names lost | 49 right, **8 overwrites**, 4 names lost |

The five overwrites the blank form adds outside the list are all the same
mistake it fixes inside it:

```
17-27-23   "praise the"             -> "Praisy's"
09-10-32   "Mira va"                -> "Mirza"
23-00-49   "Versailles,"            -> "Vercel,"
10-23-28   "transcription when the" -> "Praisy"
10-23-28   "press"                  -> "Praisy's"
```

`23-00-49` is the one to read twice. It is `alternatives for Versailles, such
as Vercel` — the speaker named both, and the blank arm wrote the vocabulary
term over the place name. That is `09-35-01` again, the clip round 1 could
never score.

One caveat on the classification. A span that `slots` merged can hold two
decisions at once, and then it lands in whichever column the whole span falls
in. `17-39-27` is such a span: true `praise Matthieu's`, blank arm
`Praisy's Matthieu's`. It is counted as a name lost, and it is also an
overwrite of "praise". One of the four.

## The blanks are not stable under letter order

A blank has to letter its own candidates, and the order is a free choice. The
arm above uses the order the app's own menu introduces them in. Sorting them
instead changes no word of the question. `--order sorted`:

| blank arm, letters in | total /53 | multi-slot /18 | collision /8 | spans right | overwrites | names lost |
|---|---|---|---|---|---|---|
| menu order | 37 | 9 | 3 | 59/77 | 14 | 4 |
| sorted | **31** | **5** | **5** | **47/77** | **20** | **10** |
| sentence arm, unaffected | 41 | 12 | 0 | 61/77 | 15 | 1 |

**Letter order moves the blank arm by 6 cases. The shape itself moves it by 4.**
It also changes *which* clips of the collision class it gets: `11-19-17` is won
in menu order and lost in sorted, and `14-09-56`, `13-09-46` and `14-11-21` go
the other way. The sentence arm keeps the app's menu untouched and scores 41
and 61/77 in both runs, which is the check that the harness is varying only
what it says it varies.

So 37/53 is not the blank form's score. It is one point in a range the form
reaches by an accident of alphabet. **A shape whose answer turns on which
candidate got the letter A is not a shape to ship**, whichever end of the range
is quoted.

Two replies were unreadable under sorted order — `2=B 3=A`, which names two of
three blanks, and `A=A B=B`. Both are counted wrong. In menu order there were
none.

## The multi-slot subset

18 of the 53 cases hold more than one uncertain span, 42 spans between them.
35 hold one span. **77 spans over 53 cases.**

The shape can only differ where a case holds more than one span. It does differ
there, and it differs the wrong way: **12/18 as sentences, 9/18 as blanks.** On
the 35 single-span cases the two arms score 29 and 28, which is one case and is
noise.

So the subset where the shape is a real question prefers the sentence.

## Per case

```
all          +4  17-19-57  11-19-17  10-12-37  15-36-12
             -8  17-39-27  17-27-23  17-05-32  09-10-32
                 14-11-36  23-00-49  10-23-28  07-36-58

multi-slot   +1  10-12-37
             -4  17-05-32  14-11-36  23-00-49  10-23-28

single-slot  +3  17-19-57  11-19-17  15-36-12
             -4  17-39-27  17-27-23  09-10-32  07-36-58
```

### What the losses have in common — a span wider than a word

Four of the eight losses hold a span that is more than one word — `17-39-27`,
`17-27-23`, `09-10-32`, `10-23-28`. `slots` merges spans that overlap, so a
span can be `praise the` or `transcription when the`. In the sentence form
those words stay in a sentence. In the blank form the frame around the blank is
what is left, and what is left is not English.

```
So let's ___1___ team's work.        <- 17-27-23, the true reading is "praise the"

1. A. praise the
   B. Praisy
   C. Praisy's
```

```
So I guess to ___1___ that loop, is there a way we can record the
final ___2___ user ___3___ enters.   <- 10-23-28, 12 options, 3 spans

2. A. transcription when the
   B. Praisy
```

The sentence arm reads `record the final transcription when the user press
enters` and takes it. The blank arm chooses between `transcription when the`
and `Praisy` inside `record the final ___ user`, which is a frame no reading
completes.

That cost is structural. A blank helps when the span is a word and hurts when
the span is a phrase. **23 of the 77 spans in this cache hold a reading of more
than one word.**

### `07-36-58` — the clip that keeps breaking

```
So let's say we have very low floor for ___1___ but with the judge. ...

1. A. Prezi,
   B. Praisy,
```

The true reading is `Praisy,`. The sentence arm takes it, the blank arm takes
`Prezi,`. PR #68 lost this clip when it cut the pro-term sentence, and round
1's position rule lost it too. The term list is still in this prompt. The blank
removes what made the list usable: the speaker is talking *about* the term, and
the blank hides the sentence that says so.

## Every number in rounds 1–3 excludes the live collisions

`tests/judge-menus.json` was harvested before PR #70. Its newest clip is
`2026-08-08T01-02-23`. The 15 clips PR #70 added were dictated the same
afternoon, 16:17 to 17:42, and **none of them are in the cache.** Re-harvesting
runs the app, so this round could not add them.

Every judge number in rounds 1, 2 and 3 — 41/53, 0/8, 37/53, 3/8, and every
number in F16, F17 and F18 — is measured on 53 menus that hold none of them.

The 15 are almost all the ordinary-word collision class, which is the class the
shipped prompt scores 0 on. This is what a harvest would add, read off the
`# app:` lines in `tests/menu-cases.yaml`:

| clip | what the pass did | would it enter the cache? |
|---|---|---|
| `16-17-03` | Vercel over "Versailles" — the replacements stage, not the spotter | no menu |
| `16-18-00` | Arexvy over "retry", Redcrawl over "crawl" | yes, 2 spans |
| `16-18-14` | Supabase over "update" | yes |
| `16-18-23` | Redcrawl over "crawl" | yes |
| `16-18-37` | Matthieu over "matches" | yes |
| `16-18-45` | Praisy over "spray"; the speaker said "praise" | yes, unreachable |
| `16-19-02` | Praisy's over "praise for" | yes |
| `16-19-18` | Praisy over "proprietary" | yes |
| `16-28-54` | nothing fired; NLTagger stayed as decoded | no menu |
| `16-29-26` | Claude over "predicting"; the speaker said "generating" | yes, unreachable |
| `17-32-26` | Arexvy over both Praisy and Prissy | yes, reachability unknown |
| `17-37-39` | Praisy over "work when"; `said` deliberately blank | skipped by the harvest |
| `17-39-32` | Praisy over "train" | yes |
| `17-40-19` | Vercel over "level", Arexvy over "heavy" | yes, 2 spans |
| `17-41-18` | Praisy's over "train as" | yes |

**12 of the 15 would enter the cache, and 9 of those would be scorable.** Two
are unreachable because the word the speaker said was never decoded, so no
menu can hold it. One cannot be called without running it.

That column is a prediction, not a measurement. It rests on one fact in the
code: `Vocabulary.autoApplies` writes a term in only when the decoded word is
**not** a real word, or is the same word with a space in it.
`Replacements.applyFuzzy` is gated on the same test. Every clip above replaced
an ordinary English word — "retry", "crawl", "update", "matches", "praise",
"proprietary", "train", "level", "heavy" — so neither could have fired, and the
judge must have been asked, which means a menu existed. Only a harvest settles
it.

Adding 9 scorable collision clips would roughly double a class the shipped
prompt is 0 of 8 on. **That is the number to want next, and it matters more
than the 4 cases this round moved.**

## The data gap, still open

Round 2 recorded it and round 3 cannot close it. On all 8 not-a-word spans in
this cache the speaker meant the vocabulary term. There is no clip where the
decoder wrote a non-word and the non-word was right, so **no rule about that
class can be falsified.** The `--sweep` result that reaches 8/8 at about 1.5
nats is unfalsifiable rather than good.

What would fill it: a clip where the speaker says a proper name that is *not*
in the vocabulary, whose spelling is in no dictionary, and which sounds like a
term that is. A colleague called `Tasmin` beside the vocabulary's `Tasmeen`. A
product called `Prezi` beside `Praisy`. `Arexvi` beside `Arexvy`. The right
answer on that span is "keep what the decoder wrote", and one such clip breaks
the 8/8 unanimity that currently makes every offset look safe.

## Recommendation

**Ship nothing, again.** There is no trade to weigh here, because the blank
form does not buy the thing it was meant to buy.

The trade looks like one case metric against another — 3/8 of the collision
class against 4 cases of the total. Per span it is not a trade at all. The
overwrite is the error that matters, and the blank form commits 14 of them
against the sentence form's 15. It halves them on the 8 clips PR #68 happened
to write down and it more than doubles them on the other 45, including
`23-00-49`, where it writes `Vercel` over the place the speaker named. **The
class did not shrink. It moved off the list we were watching.** On top of that
the blanks lose 4 names where the sentence loses 1.

If the numbers had come out the other way — collision class up, total down —
the decision would be Nathan's. They did not. Both metrics say the same thing
once they are counted per span.

There is also nothing stable to ship. Sorting the candidates inside a blank
changes no word of the question and moves the arm 6 cases, from 37 to 31, and
the overwrite count from 14 to 20. The shape moves the total by 4. The choice
of which candidate gets the letter A moves it by more.

One thing is still worth keeping, and it is what the shape is for. `10-12-37`
is the only multi-slot collision clip any arm in three rounds has got, and both
blank arms get it. A blank is right for a span that is one word and wrong for a
span that is a phrase. If the blanks are tried again, change the slot recovery
and not the prompt: a merged span of four words should not be a blank at all,
and 23 of the 77 spans here hold a reading of more than one word.

Do the harvest first. Nine more collision clips against a prompt that scores 0
of 8 on that class will say more than a fourth wording.

Recorded as F19 in [vocabulary-v2.md](vocabulary-v2.md).
