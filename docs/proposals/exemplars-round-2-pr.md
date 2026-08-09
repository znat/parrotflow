# Intended PR body — `spike/exemplars-round-2`

Not opened. `gh pr create` was not run. Title:

> test: record the terms that cost clips, and measure the separation on them

---

**It works on `Redcrawl` and `Supabase`. 48 scripted lines took the vocabulary
from 27 recordings over 4 terms to 122 over 11. On round 6's own set the
headline rises from 0.812 to 0.874 and nothing is dropped any more. On a second
set read off the labels of the 48 clips — the only set with an A row for
`Redcrawl` — `Redcrawl` is 0.966 over 8 A / 63 B and `Supabase` is 1.000 over 9
A / 62 B, pooled 0.935. 7 of the 8 words the app actually wrote a name over sit
farther from that name than every real utterance of it.**

## Why

Round 6 (`spike/reference-matching`, not merged) showed that comparing a span
to recordings of the term separates "the term was said" from "the term was not
said" at AUC 0.812, against 0.318 for the acoustic score. It could only test
four terms. The two costing clips — `Redcrawl` with no recording, `Supabase`
with one — were dropped. Its recommendation was to record them.

## What was recorded

48 lines read on 2026-08-09, one dictation each. They align 1:1 and
monotonically against `parrotflow-recording-script.md`: 48 clips, 48 lines, no
line skipped and none restarted whole. Five diverge from the script beyond a
mangled name and are labelled with what he said. `14-00-56` is flagged twice —
a word before the sentence, decoded `Myrza` at confidence 0.29, and "roles"
where the script says "rows".

They go into `tests/menu-cases.yaml` as block 4, with a comment saying they are
read speech and not dictation. The audio stays out of the repository, in
`voice/samples/<Term>/`. `scripts/check-no-voice.sh` passes.

| term | round 6 | spontaneous | scripted | total |
|---|---|---|---|---|
| **Redcrawl** | **0** | **0** | **8** | **8** |
| **Supabase** | **1** | **2** | **9** | **11** |
| Arexvy | 0 | 1 | 6 | 7 |
| Claude | 0 | 0 | 6 | 6 |
| Matthieu | 2 | 4 | 7 | 11 |
| Mirza | 0 | 7 | 8 | 15 |
| Ollama | 0 | 1 | 6 | 7 |
| Praisy | 17 | 26 | 0 | 26 |
| Redrock | 0 | 0 | 7 | 7 |
| Tasmeen | 0 | 2 | 6 | 8 |
| Vercel | 7 | 16 | 0 | 16 |
| **total** | **27** | **59** | **63** | **122** |

The spontaneous column grew without a new line being read.
`scripts/mine-pronunciations.py` now counts a possessive as the name and keeps
the occurrences the decoder got right, and it reads word times from
`trace.jsonl` instead of running the app — so mining an archive that was
already traced needs no build.

## Set 1 — round 6's own set

Same proposals, same deduplication, same hold-out. The port reproduces round 6
exactly at `--source round6`.

| recordings | rec | A | B | AUC |
|---|---|---|---|---|
| round 6 | 27 | 30 | 46 | 0.812 |
| spontaneous, re-mined | 59 | 32 | 57 | 0.831 |
| scripted only | 63 | 6 | 24 | 0.910 |
| **all** | **122** | **33** | **66** | **0.874** |
| the raw acoustic score | — | 33 | 66 | 0.318 |

Round 6 dropped 23 of round 5's 99 rows. This drops none. `Matthieu` went from
0.556 on 2 recordings to 1.000 on 11.

## Set 1 does not answer the question

Five terms have no A row, `Redcrawl` among them. Group A means the pass offered
the term where the term really was, and in the whole spontaneous archive it
never once offered `Redcrawl` correctly — all 3 of its rows are wrong offers.
Recordings cannot create a pair to rank.

## Set 2 — the scripted clips

A and B read straight off the labels. B holds the other ten names and the 8
ordinary words the pass actually wrote a name over, so nothing easy is in it:
`Redrock` is a negative for `Redcrawl`, `praise` for `Praisy`. Same hold-out, by
clip, for both groups.

| term | rec | A | B | AUC |
|---|---|---|---|---|
| **Supabase** | **11** | **9** | **62** | **1.000** |
| Redrock | 7 | 7 | 64 | 0.993 |
| Tasmeen | 8 | 6 | 65 | 0.985 |
| **Redcrawl** | **8** | **8** | **63** | **0.966** |
| Mirza | 15 | 8 | 63 | 0.940 |
| Arexvy | 7 | 6 | 65 | 0.936 |
| Ollama | 7 | 6 | 65 | 0.874 |
| Matthieu | 11 | 7 | 64 | 0.848 |
| Claude | 6 | 6 | 65 | 0.844 |
| **pooled** | | **63** | **718** | **0.935** |

## The control

| set | group | AUC(matched vs mismatched) | matched is nearer |
|---|---|---|---|
| round 6 | A | 0.893 | 27/30 (90%) |
| round 6 | B | 0.762 | 37/46 (80%) |
| round 7 proposals | A | 0.816 | 29/33 (88%) |
| round 7 proposals | B | 0.453 | 31/66 (47%) |
| scripted set | A | 0.832 | 58/63 (92%) |
| scripted set | B | 0.076 | 13/718 (2%) |

Round 6's B row was the problem. A B span has no business being nearer the
term's recordings than any other term's, and 80% said the distance carried
something generic — with 17 of 27 recordings being `Praisy`, "nearest
mismatched" was mostly "nearest of 17 `Praisy`". Eleven terms fix it. Length
does not explain the result either: AUC on span duration alone is 0.535, and
holding the length gap equal to ±0.05s the distance still separates at 0.879.

## The 8 live overwrites

| the app heard | and wrote | distance | nearer than |
|---|---|---|---|
| `update` | Supabase | 3.135 | 0 of 9 real spans |
| `crawl` | Redcrawl | 3.142 | 0 of 8 |
| `slide` | Claude | 3.194 | **1 of 6** |
| `retry` | Arexvy | 3.328 | 0 of 6 |
| `general` | Redcrawl | 3.328 | 0 of 8 |
| `already` | Arexvy | 3.380 | 0 of 6 |
| `train` | Praisy | 3.520 | 0 of 21 |
| `ready` | Arexvy | 3.575 | 0 of 6 |

`update`→`Supabase` and `general`→`Redcrawl` are F1 and F5.

## What is weak about it

**Read speech flatters the result by about 0.06.** Scored against spontaneous
recordings only — different day, dictation not reading — the scripted spans give
0.856 pooled against 0.920 same-session. `Supabase` survives at 0.991 on two
spontaneous recordings, which answers round 6's open question about thin terms.

**`Redcrawl`, `Redrock` and `Claude` cannot take that test.** They have no
spontaneous recording. Their numbers are read speech compared with read speech
from the same six minutes. `Redcrawl` at 0.966 is the weakest-supported row in
the table.

**Set 2's B group is mostly other names**, not the ordinary words a spotter
offers a name over. There are only 8 of those in these clips.

**Do not tune a threshold on set 2.** Every A span in it is one session of read
speech, and round 6 already showed the scale differs per term.

## Not changed

No app, no build, no install, no model call, no Ollama. Everything reads wavs
and `trace.jsonl` and does arithmetic. The user's app is still at stamp
`78d7ba2`. Nothing under `~/.config/parrotflow-dev/` was touched except the new
`voice/` directory.

## Recommendation

Collect audio on a correction, not only from scripts — PR 8 already writes the
observation. Still do not ship MFCC + DTW: 122 recordings over 781 span-term
pairs cost four minutes of a dynamic program per recording per span, and a
speech encoder with one vector per recording and a cosine is stronger and
cheaper. This round says the comparison to recordings is the right question. It
does not say this is the right implementation of it.

Round 7 in [judge-framings.md](judge-framings.md). Finding F21 in
[vocabulary-v2.md](vocabulary-v2.md). Per-proposal distances in
[reference-matching-distances.md](reference-matching-distances.md).
