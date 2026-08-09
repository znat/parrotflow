# Every proposal, with its distance to the nearest recording

Produced by `scripts/reference-matching.py --table`. Read the
round in [judge-framings.md](judge-framings.md) first — this
file is the evidence under it, not an argument.

`matched` is the DTW distance from the span to the nearest
recording of the same term, over MFCCs, with any recording cut
from this same clip held out. `mismatched` is the same number
against recordings of every other term. Lower is nearer.
`held` is how many recordings of the term survived the hold-out.

| clip | group | kind | term | heard | span | held | matched | nearest | mismatched |
|---|---|---|---|---|---|---|---|---|---|
| 07T15-21-29 | A | rescorer | Matthieu | Mathieu | 7.20-8.08 | 10 | 2.874 | 01-mathieu's.wav | 3.183 |
| 06T14-11-36 | A | rescorer | Matthieu | Matthew | 0.24-0.88 | 10 | 2.998 | 06-matthew.wav | 2.962 |
| 07T17-39-40 | A | rescorer | Matthieu | Mathieu | 1.36-1.84 | 10 | 3.027 | 06-matthew.wav | 3.159 |
| 06T14-11-48 | A | rescorer | Ollama | Olama | 1.36-1.84 | 6 | 3.313 | 06-olemalogues.wav | 3.250 |
| 07T15-21-19 | A | rescorer | Praisy | Prissy | 0.00-0.64 | 25 | 2.328 | 19-pressy.wav | 3.120 |
| 07T15-21-23 | A | rescorer | Praisy | Pressy | 0.16-0.88 | 25 | 2.328 | 20-prissy.wav | 2.992 |
| 07T17-05-32 | A | spotter | Praisy | Prizzi and | 0.56-1.36 | 25 | 2.375 | 11-prissyd.wav | 2.803 |
| 07T15-36-40 | A | rescorer | Praisy | Prissy | 0.16-0.80 | 25 | 2.426 | 19-pressy.wav | 3.103 |
| 07T16-09-15 | A | rescorer | Praisy | Priss.y | 14.48-15.12 | 25 | 2.471 | 09-prissy.wav | 3.334 |
| 07T16-09-37 | A | rescorer | Praisy | Prissy | 2.32-2.96 | 25 | 2.471 | 10-prissy.wav | 3.346 |
| 07T16-09-06 | A | rescorer | Praisy | Prissy | 0.24-0.72 | 25 | 2.509 | 25-precy.wav | 2.906 |
| 07T16-09-50 | A | rescorer | Praisy | Prissy | 1.44-2.08 | 25 | 2.583 | 09-prissy.wav | 3.277 |
| 07T17-38-57 | A | rescorer | Praisy | Precise | 1.28-1.84 | 25 | 2.623 | 11-prissyd.wav | 3.020 |
| 07T15-36-50 | A | rescorer | Praisy | Prissy | 2.88-3.52 | 25 | 2.695 | 18-prissy.wav | 3.055 |
| 07T13-19-22 | A | rescorer | Praisy | Prissy | 1.04-1.44 | 25 | 2.698 | 20-prissy.wav | 3.274 |
| 07T16-16-25 | A | spotter | Praisy | praise | 21.60-22.08 | 25 | 2.854 | 14-praise.wav | 3.252 |
| 07T16-16-25 | A | rescorer | Praisy | praise. | 21.60-22.08 | 25 | 2.854 | 14-praise.wav | 3.252 |
| 06T14-11-48 | A | rescorer | Praisy | Prissy | 0.16-0.96 | 25 | 2.902 | 11-prissyd.wav | 3.124 |
| 07T17-38-44 | A | spotter | Praisy | Pressy | 6.96-7.60 | 25 | 2.908 | 17-prissy.wav | 3.239 |
| 07T17-05-12 | A | rescorer | Praisy | praise | 1.28-1.60 | 25 | 3.074 | 01-precise.wav | 3.301 |
| 07T15-37-32 | A | rescorer | Praisy | Pressy. | 0.88-1.60 | 25 | 3.078 | 16-pressy.wav | 3.348 |
| 07T16-12-33 | A | spotter | Praisy | Prezi | 2.08-4.40 | 25 | 3.094 | 16-pressy.wav | 3.096 |
| 07T16-09-00 | A | rescorer | Praisy | Prissy | 0.40-1.12 | 25 | 3.137 | 11-prissyd.wav | 3.159 |
| 07T15-37-38 | A | spotter | Praisy | praise, P-R-A-I-S-E | 14.72-18.72 | 25 | 3.297 | 16-pressy.wav | 3.336 |
| 07T17-39-03 | A | spotter | Praisy | his | 7.44-7.60 | 25 | 3.348 | 14-praise.wav | 3.525 |
| 07T17-05-42 | A | rescorer | Supabase | superbase | 14.80-15.52 | 10 | 2.919 | 07-superbase.wav | 3.285 |
| 04T10-12-37 | A | rescorer | Tasmeen | Tasmin | 2.88-3.36 | 7 | 3.268 | 03-dasmean.wav | 3.303 |
| 07T13-09-30 | A | rescorer | Vercel | versal | 1.28-1.68 | 15 | 2.883 | 04-versal.wav | 3.139 |
| 07T17-05-32 | A | rescorer | Vercel | versal | 3.52-4.00 | 15 | 2.883 | 11-versal.wav | 3.107 |
| 07T17-39-40 | A | spotter | Vercel | Versailles | 18.56-19.44 | 15 | 2.927 | 01-versal.wav | 3.238 |
| 07T17-26-30 | A | rescorer | Vercel | Versal. | 4.88-5.52 | 15 | 2.951 | 01-versal.wav | 2.906 |
| 06T14-11-21 | A | rescorer | Vercel | Versal | 3.92-4.56 | 15 | 3.005 | 06-versailles.wav | 3.177 |
| 07T13-10-53 | A | rescorer | Vercel | Versal | 0.16-0.80 | 15 | 3.178 | 11-versal.wav | 2.992 |
| 08T16-18-00 | B | rescorer | Arexvy | retry | 1.12-1.60 | 7 | 3.613 | 00-rxv.wav | 3.195 |
| 07T10-23-28 | B | rescorer | Claude | close | 5.52-5.92 | 6 | 3.111 | 04-claude's.wav | 3.272 |
| 06T13-20-20 | B | spotter | Claude | deployment | 23.44-24.16 | 6 | 3.363 | 03-claude.wav | 3.302 |
| 07T14-47-26 | B | spotter | Claude | explanation | 42.64-43.60 | 6 | 3.439 | 03-claude.wav | 3.151 |
| 07T17-39-40 | B | spotter | Claude | deployed on | 17.92-18.56 | 6 | 3.476 | 05-cloud.wav | 3.197 |
| 06T22-51-48 | B | spotter | Claude | try | 4.32-4.72 | 6 | 3.595 | 04-claude's.wav | 3.307 |
| 04T12-54-09 | B | spotter | Matthieu | activation | 1.20-1.84 | 11 | 3.275 | 02-mathieu.wav | 3.385 |
| 07T17-39-40 | B | spotter | Matthieu | went to the | 3.12-3.84 | 10 | 3.279 | 08-match's.wav | 3.023 |
| 06T13-20-20 | B | rescorer | Matthieu | last thing | 0.48-0.96 | 11 | 3.398 | 00-mathieu.wav | 3.145 |
| 07T17-39-19 | B | rescorer | Mirza | Mirza's | 2.48-3.36 | 14 | 2.937 | 03-mirza.wav | 3.310 |
| 06T09-10-32 | B | rescorer | Mirza | Mira | 2.96-3.36 | 15 | 3.283 | 02-mirza.wav | 3.403 |
| 05T23-00-49 | B | spotter | Mirza | Versailles | 13.28-14.64 | 15 | 3.375 | 07-murza.wav | 3.177 |
| 06T14-04-21 | B | spotter | Mirza | data | 69.28-69.92 | 15 | 3.413 | 13-mirza's.wav | 3.315 |
| 06T13-20-20 | B | spotter | Ollama | vocabulary | 8.08-8.80 | 7 | 3.316 | 01-olama.wav | 3.164 |
| 06T11-10-43 | B | spotter | Ollama | explanation | 6.08-7.12 | 7 | 3.476 | 04-olama.wav | 3.344 |
| 08T16-19-02 | B | rescorer | Praisy | praise | 2.40-3.04 | 26 | 2.495 | 25-precy.wav | 2.797 |
| 07T15-37-38 | B | rescorer | Praisy | pressi? | 24.80-26.16 | 25 | 2.717 | 16-pressy.wav | 3.231 |
| 07T16-12-20 | B | rescorer | Praisy | praise. | 2.40-3.36 | 26 | 2.910 | 14-praise.wav | 3.062 |
| 07T16-16-25 | B | spotter | Praisy | praise | 20.80-21.12 | 25 | 2.922 | 01-precise.wav | 3.286 |
| 07T16-16-25 | B | rescorer | Praisy | praise | 20.80-21.12 | 25 | 2.922 | 01-precise.wav | 3.286 |
| 07T16-09-15 | B | rescorer | Praisy | praise | 12.80-13.44 | 25 | 2.923 | 14-praise.wav | 3.009 |
| 07T17-39-03 | B | rescorer | Praisy | praise | 5.68-6.16 | 25 | 2.943 | 11-prissyd.wav | 3.241 |
| 07T17-39-19 | B | rescorer | Praisy | praise | 2.00-2.48 | 26 | 3.003 | 00-praisehis.wav | 3.178 |
| 07T18-05-16 | B | rescorer | Praisy | press | 10.16-10.64 | 26 | 3.061 | 00-praisehis.wav | 3.303 |
| 07T16-16-25 | B | spotter | Praisy | heard by | 11.20-12.72 | 25 | 3.112 | 04-prizzi.wav | 3.189 |
| 06T13-51-22 | B | spotter | Praisy | indexé | 21.36-22.16 | 26 | 3.119 | 07-prezi.wav | 3.276 |
| 07T08-13-36 | B | spotter | Praisy | specifically | 11.60-12.56 | 26 | 3.140 | 07-prezi.wav | 3.271 |
| 06T15-36-12 | B | rescorer | Praisy | Pretty | 0.24-0.56 | 26 | 3.145 | 04-prizzi.wav | 3.134 |
| 07T16-12-33 | B | spotter | Praisy | replaced it with | 1.12-2.08 | 25 | 3.165 | 00-praisehis.wav | 3.294 |
| 04T12-54-09 | B | spotter | Praisy | phrase plus not | 1.84-4.72 | 26 | 3.170 | 14-praise.wav | 3.229 |
| 06T13-20-20 | B | spotter | Praisy | person | 17.12-17.44 | 26 | 3.198 | 25-precy.wav | 3.340 |
| 07T17-05-42 | B | spotter | Praisy | database | 16.32-17.04 | 26 | 3.231 | 14-praise.wav | 3.071 |
| 07T15-37-24 | B | rescorer | Praisy | praise | 0.96-1.44 | 25 | 3.234 | 05-praise.wav | 3.306 |
| 07T15-37-32 | B | rescorer | Praisy | praise | 0.40-0.72 | 25 | 3.250 | 05-praise.wav | 3.378 |
| 07T10-23-28 | B | spotter | Praisy | transcription when the | 12.40-14.32 | 26 | 3.257 | 07-prezi.wav | 3.346 |
| 07T14-47-26 | B | spotter | Praisy | through | 21.12-21.60 | 26 | 3.276 | 04-prizzi.wav | 3.368 |
| 04T11-19-17 | B | spotter | Praisy | proprietary | 3.68-4.56 | 26 | 3.282 | 17-prissy.wav | 3.326 |
| 06T12-12-16 | B | spotter | Praisy | Currently | 2.56-3.28 | 26 | 3.311 | 17-prissy.wav | 3.206 |
| 08T17-40-19 | B | spotter | Praisy | fast on | 18.72-19.20 | 26 | 3.311 | 00-praisehis.wav | 3.186 |
| 06T14-09-56 | B | spotter | Praisy | vocabulary | 20.08-21.04 | 26 | 3.321 | 17-prissy.wav | 3.190 |
| 06T14-04-21 | B | spotter | Praisy | explanations | 19.36-20.48 | 26 | 3.327 | 23-prissy.wav | 3.326 |
| 06T15-47-25 | B | spotter | Praisy | press ASC during | 10.08-14.32 | 26 | 3.334 | 07-prezi.wav | 3.253 |
| 04T12-54-09 | B | spotter | Praisy | Patrick | 5.52-6.40 | 26 | 3.334 | 14-praise.wav | 3.363 |
| 06T15-47-25 | B | spotter | Praisy | or transcribing | 21.20-22.32 | 26 | 3.341 | 17-prissy.wav | 3.156 |
| 07T08-13-36 | B | spotter | Praisy | was a lot | 28.88-29.28 | 26 | 3.362 | 07-prezi.wav | 3.330 |
| 06T14-12-30 | B | spotter | Praisy | praise | 0.88-1.28 | 26 | 3.374 | 14-praise.wav | 3.229 |
| 07T16-09-50 | B | rescorer | Praisy | praise | 0.72-1.04 | 25 | 3.377 | 21-preced.wav | 3.376 |
| 07T17-50-00 | B | spotter | Praisy | sentences | 16.24-17.20 | 26 | 3.383 | 07-prezi.wav | 3.251 |
| 07T17-05-12 | B | rescorer | Praisy | praise | 0.72-1.04 | 25 | 3.406 | 21-preced.wav | 3.249 |
| 06T13-20-20 | B | spotter | Praisy | person or a | 17.12-17.92 | 26 | 3.442 | 16-pressy.wav | 3.284 |
| 08T17-40-19 | B | rescorer | Praisy | train | 12.72-13.20 | 26 | 3.451 | 12-prissy.wav | 3.381 |
| 08T17-41-18 | B | rescorer | Praisy | train | 3.44-3.84 | 26 | 3.565 | 11-prissyd.wav | 3.361 |
| 06T14-11-21 | B | spotter | Redcrawl | the crawl | 2.56-3.12 | 8 | 3.098 | 01-redcrawl.wav | 3.150 |
| 06T14-04-21 | B | rescorer | Redcrawl | queries crawl | 71.20-73.36 | 8 | 3.234 | 00-redcrawl.wav | 3.048 |
| 08T00-14-39 | B | rescorer | Redcrawl | general | 4.56-4.88 | 8 | 3.727 | 03-redcrawl.wav | 3.341 |
| 06T13-51-22 | B | rescorer | Redrock | renforcé | 26.56-27.28 | 7 | 3.538 | 06-redrock.wav | 3.266 |
| 08T01-02-23 | B | rescorer | Supabase | update | 1.12-1.60 | 11 | 3.449 | 03-superbase.wav | 3.428 |
| 07T17-05-42 | B | spotter | Supabase | super base | 10.48-10.96 | 10 | 3.470 | 05-superbase.wav | 3.430 |
| 05T23-00-49 | B | spotter | Tasmeen | possible | 9.76-10.24 | 8 | 3.107 | 03-dasmean.wav | 2.988 |
| 07T12-35-15 | B | spotter | Tasmeen | text to | 0.96-1.68 | 8 | 3.349 | 00-tasmine.wav | 3.329 |
| 04T13-15-26 | B | spotter | Tasmeen | on a file | 16.16-17.44 | 8 | 3.448 | 04-dasmean.wav | 3.226 |
| 07T17-39-40 | B | spotter | Vercel | universal | 12.24-12.88 | 15 | 3.041 | 04-versal.wav | 3.148 |
| 04T10-28-14 | B | rescorer | Vercel | merge? | 10.32-11.28 | 16 | 3.122 | 08-versal.wav | 3.284 |
| 07T16-04-42 | B | spotter | Vercel | Versailles | 5.84-6.56 | 15 | 3.180 | 13-versal.wav | 3.261 |
| 08T17-40-19 | B | rescorer | Vercel | level. | 9.84-10.40 | 16 | 3.216 | 12-versailles.wav | 3.256 |
| 06T22-51-48 | B | spotter | Vercel | number of | 5.68-6.24 | 16 | 3.330 | 11-versal.wav | 3.334 |

## Dropped

| clip | group | term | why |
|---|---|---|---|
