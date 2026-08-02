# Pipelines

Everything a finished transcript goes through, in order, per language:

```yaml
transcription:
  pipelines:
    default: [replacements, fuzzy, numbers]
    fr: [replacements, fuzzy, numbers]
```

A language's own list wins over `default`. A key that is neither `default` nor
one of your `languages:` is reported by `--check-config` rather than silently
never running.

Being in a pipeline is the only way a stage runs, which is why a new install is
written with all of them spelled out: turning one off means deleting a line you
can see, not finding a setting you cannot. Delete `pipelines:` entirely and you
get every stage back — a missing section is silence, not a choice. Write
`default: []` and you get none, which is a choice.

## The stages

| Stage | What it does |
|---|---|
| `replacements` | The substitutions in `replacements:` — literal, word-boundary, case-insensitive, or a regex between slashes. |
| `fuzzy` | The same table against renderings you have not taught, so "super bays" reaches Supabase. Only words the spell checker does not know are eligible, which is what keeps "Excel" from becoming "Vercel". Needs `replacements` before it and says so if it does not have one, because on its own it swallows the preceding word. |
| `numbers` | Spoken numbers as digits: "two hundred forty-three" → 243, plus ordinals, decimals, years and spoken digits. English and French, septante/huitante/nonante included, chosen per transcript. A number word on its own stays a word below ten, so "chapter three" and "on est deux" are left alone. |

`numbers` rewrites transcripts that were already correct, so run `--numbers` on
a line to see exactly what it would do before leaving it in.

## Conditions

A stage can carry a condition, which is what makes an expensive one affordable
— it is skipped on the transcripts that do not need it:

```yaml
pipelines:
  fr:
    - replacements
    - stage: fuzzy
      unless: /```/                      # never inside a code fence
    - stage: numbers
      when: /\b(vingt|cent|mille)\b/     # only if a number word is left
```

`when` and `unless` read the text *as it stands at that point*, after the
stages above — so a cheap stage can make an expensive one unnecessary rather
than merely earlier. Both may be set and `unless` wins, because a reason not to
run is a stronger statement than a reason to.

The pattern is written like a replacement source: between slashes it is a
regular expression, otherwise a word matched on word boundaries.
Case-insensitive either way.

A skipped stage says so in the log. A stage that silently does not run looks
exactly like one that ran and found nothing, and only one of those is
answerable by editing a condition.

## Apps

`app:` runs a stage only where you want it — the rewrite that belongs in a
terminal and nowhere near an email:

```yaml
pipelines:
  default:
    - replacements
    - stage: numbers
      app: /term|ghostty|iterm|warp/
    - prompt: prose
      app: /^(?!.*(term|ghostty|iterm|warp))/
```

**There is no `not_app:`.** The pattern is a regular expression like every
other one here, so exclusion is a negative lookahead. One key covers both
directions, at the cost of the anchor in `/^(?!.*…)/` — and forgetting it is
not a silent failure: `--check-config` and `--pipeline` both refuse an
unanchored lookahead, because unanchored it matches one character into the very
name it was meant to exclude, and the stage would run everywhere.

**The app is the one that was in front when the hotkey went down**, not when
the transcript came back. Between the two there is a transcription and possibly
a model call, and the window you dictated into is not reliably still in front.

**Name and bundle identifier are matched as one string** — `Ghostty
com.mitchellh.ghostty` — so a pattern can name either. Match on the identifier
when you want the rule to survive someone renaming an app, on the name when you
want to read it back in six months. It is one string rather than two on
purpose: `/^(?!.*microsoft)/` matches `Code` while failing
`com.microsoft.VSCode`, and "either one matched" would run the stage in the app
it was written to exclude.

**No app means the stage does not run.** On a path with no window to read, a
positive `app:` fails closed — running anyway would put a terminal-only stage
everywhere else, which is the one outcome the condition existed to prevent. The
log says which it was.

To try one without speaking into the right window:

```sh
ParrotFlow --pipeline tests/pipelines/apps.yaml "on en a vingt et un" --app Ghostty
```

An empty `--app ""` means "nothing in front" rather than "no flag given" — the
two are the same question, and saying so lets a caller pass the flag
unconditionally. `scripts/check-pipeline.sh` relies on it.

### What app conditions do not do

**They do not need Accessibility.** The app is read from `NSWorkspace`, not off
the focused element, so gating a stage by app costs no permission that gating
it by text does not.

**They only apply to dictation.** The pipeline runs on a transcript on its way
into a window. A voice command — anything after the activation phrase — is
routed and transformed on a different path that never assembles a pipeline, so
an `app:` there gates nothing. `--replace` likewise passes no app, which means
an app-conditioned stage never runs under it; that is the fail-closed rule
doing its job on a path with no window, not a bug to work around.

**Negation reads differently for text and for apps.** `unless:` excludes on
text; an app is excluded with a negative lookahead inside `app:`. Two idioms
for one idea, and the reason is that an app pattern is matched against one
joined string where a lookahead is exact, while a second key would have been a
second thing to learn for a case the pattern already covers. Worth knowing
before you go looking for `not_app:` — it is not there and will not be.

**A stage is gated, not parameterised.** `app:` decides whether a stage runs.
It cannot hand the stage a different table or a different prompt per app; two
behaviours mean two steps, each with its own condition.

## Prompt stages

A prompt from `prompts:` can be a stage too, and it is the reason conditions
exist: it calls the local model, so it costs about a second where every other
stage costs nothing. Measured on one line, 3.2s with the prompt running against
0.035s with it skipped.

```yaml
- prompt: hesitation
  when: /\b(genre|du coup|en fait)\b/
```

It is the only stage that rewrites your words without you asking, and nothing
on screen shows it happened — so every rewrite is written to the log with the
text before and after.

If the model is not running, the prompt does not exist, or the call fails, the
transcript comes back exactly as it arrived. A dictation tool can afford to
skip a stage and cannot afford to lose a sentence.

## Why there is no `dates` or `digits` prompt

There used to be both, and `free_form` does their job. On the sixteen cases
they covered in `tests/generic-cases.yaml` they scored 12/16 against the
built-in's 14/16. `digits` was a straight tie, five cases to five. `dates` was
worse — asked to make "the deadline is March 3 2026" ISO it answered
"2026-03-03", dropping the sentence around the date, which is what a prompt
written for one subject does when handed a whole sentence.

`grammar` ships for the opposite reason. It has a validation set of its own and
beats the built-in on it, 5/5 against 4/5, and the case it wins is the one that
matters most here: leaving alone a sentence that was already right.
