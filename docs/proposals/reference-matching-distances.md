# Every proposal, with its distance to the nearest recording

Produced by `scripts/reference-matching.py --table`. Read the
round in [judge-framings.md](judge-framings.md) first — this
file is the evidence under it, not an argument.

`matched` is the DTW distance from the span to the nearest
recording of the same term, over MFCCs, with any recording cut
from this same clip held out. `mismatched` is the same number
against recordings of the other three terms. Lower is nearer.
`held` is how many recordings of the term survived the hold-out.

| clip | group | kind | term | heard | span | held | matched | nearest | mismatched |
|---|---|---|---|---|---|---|---|---|---|
| 06T14-11-36 | A | rescorer | Matthieu | Matthew | 0.24-0.88 | 2 | 3.218 | 00-mathieu.wav | 3.234 |
| 07T15-21-29 | A | rescorer | Matthieu | Mathieu | 7.20-8.08 | 1 | 3.442 | 00-mathieu.wav | 3.249 |
| 07T17-39-40 | A | rescorer | Matthieu | Mathieu | 1.36-1.84 | 1 | 3.442 | 01-mathieu.wav | 3.159 |
| 07T15-21-19 | A | rescorer | Praisy | Prissy | 0.00-0.64 | 16 | 2.328 | 15-pressy.wav | 3.270 |
| 07T15-21-23 | A | rescorer | Praisy | Pressy | 0.16-0.88 | 16 | 2.328 | 16-prissy.wav | 3.249 |
| 07T17-05-32 | A | spotter | Praisy | Prizzi and | 0.56-1.36 | 16 | 2.375 | 08-prissyd.wav | 3.175 |
| 07T15-36-40 | A | rescorer | Praisy | Prissy | 0.16-0.80 | 16 | 2.426 | 15-pressy.wav | 3.434 |
| 07T16-09-15 | A | rescorer | Praisy | Priss.y | 14.48-15.12 | 16 | 2.471 | 06-prissy.wav | 3.334 |
| 07T16-09-37 | A | rescorer | Praisy | Prissy | 2.32-2.96 | 16 | 2.471 | 07-prissy.wav | 3.447 |
| 07T16-09-06 | A | rescorer | Praisy | Prissy | 0.24-0.72 | 16 | 2.546 | 02-prizzi.wav | 3.371 |
| 07T16-09-50 | A | rescorer | Praisy | Prissy | 1.44-2.08 | 16 | 2.583 | 06-prissy.wav | 3.414 |
| 07T17-38-57 | A | rescorer | Praisy | Precise | 1.28-1.84 | 17 | 2.623 | 08-prissyd.wav | 3.416 |
| 07T15-36-50 | A | rescorer | Praisy | Prissy | 2.88-3.52 | 16 | 2.695 | 14-prissy.wav | 3.414 |
| 07T13-19-22 | A | rescorer | Praisy | Prissy | 1.04-1.44 | 17 | 2.698 | 16-prissy.wav | 3.472 |
| 07T16-16-25 | A | spotter | Praisy | praise | 21.60-22.08 | 16 | 2.854 | 10-praise.wav | 3.336 |
| 07T16-16-25 | A | rescorer | Praisy | praise. | 21.60-22.08 | 16 | 2.854 | 10-praise.wav | 3.336 |
| 06T14-11-48 | A | rescorer | Praisy | Prissy | 0.16-0.96 | 17 | 2.902 | 08-prissyd.wav | 3.379 |
| 07T17-38-44 | A | spotter | Praisy | Pressy | 6.96-7.60 | 16 | 2.908 | 13-prissy.wav | 3.541 |
| 07T15-37-32 | A | rescorer | Praisy | Pressy. | 0.88-1.60 | 16 | 3.078 | 12-pressy.wav | 3.345 |
| 07T16-12-33 | A | spotter | Praisy | Prezi | 2.08-4.40 | 16 | 3.094 | 12-pressy.wav | 3.243 |
| 07T16-09-00 | A | rescorer | Praisy | Prissy | 0.40-1.12 | 16 | 3.137 | 08-prissyd.wav | 3.413 |
| 07T17-05-12 | A | rescorer | Praisy | praise | 1.28-1.60 | 17 | 3.207 | 02-prizzi.wav | 3.573 |
| 07T15-37-38 | A | spotter | Praisy | praise, P-R-A-I-S-E | 14.72-18.72 | 16 | 3.297 | 12-pressy.wav | 3.394 |
| 07T17-39-03 | A | spotter | Praisy | his | 7.44-7.60 | 17 | 3.348 | 10-praise.wav | 3.525 |
| 07T13-09-30 | A | rescorer | Vercel | versal | 1.28-1.68 | 7 | 2.883 | 04-versal.wav | 3.272 |
| 07T17-39-40 | A | spotter | Vercel | Versailles | 18.56-19.44 | 6 | 2.927 | 01-versal.wav | 3.247 |
| 07T17-26-30 | A | rescorer | Vercel | Versal. | 4.88-5.52 | 6 | 2.951 | 01-versal.wav | 3.350 |
| 06T14-11-21 | A | rescorer | Vercel | Versal | 3.92-4.56 | 7 | 3.005 | 06-versailles.wav | 3.465 |
| 07T17-05-32 | A | rescorer | Vercel | versal | 3.52-4.00 | 6 | 3.199 | 06-versailles.wav | 3.334 |
| 07T13-10-53 | A | rescorer | Vercel | Versal | 0.16-0.80 | 7 | 3.328 | 05-versal.wav | 2.992 |
| 04T12-54-09 | B | spotter | Matthieu | activation | 1.20-1.84 | 2 | 3.275 | 01-mathieu.wav | 3.418 |
| 06T13-20-20 | B | rescorer | Matthieu | last thing | 0.48-0.96 | 2 | 3.398 | 00-mathieu.wav | 3.370 |
| 07T17-39-40 | B | spotter | Matthieu | went to the | 3.12-3.84 | 1 | 3.470 | 01-mathieu.wav | 3.128 |
| 07T15-37-38 | B | rescorer | Praisy | pressi? | 24.80-26.16 | 16 | 2.717 | 12-pressy.wav | 3.277 |
| 08T16-19-02 | B | rescorer | Praisy | praise | 2.40-3.04 | 17 | 2.794 | 08-prissyd.wav | 3.259 |
| 07T16-12-20 | B | rescorer | Praisy | praise. | 2.40-3.36 | 17 | 2.910 | 10-praise.wav | 3.376 |
| 07T16-09-15 | B | rescorer | Praisy | praise | 12.80-13.44 | 16 | 2.923 | 10-praise.wav | 3.348 |
| 07T17-39-03 | B | rescorer | Praisy | praise | 5.68-6.16 | 17 | 2.943 | 08-prissyd.wav | 3.544 |
| 07T16-16-25 | B | spotter | Praisy | praise | 20.80-21.12 | 16 | 3.035 | 08-prissyd.wav | 3.485 |
| 07T16-16-25 | B | rescorer | Praisy | praise | 20.80-21.12 | 16 | 3.035 | 08-prissyd.wav | 3.485 |
| 07T18-05-16 | B | rescorer | Praisy | press | 10.16-10.64 | 17 | 3.071 | 15-pressy.wav | 3.429 |
| 07T16-16-25 | B | spotter | Praisy | heard by | 11.20-12.72 | 16 | 3.112 | 02-prizzi.wav | 3.231 |
| 06T13-51-22 | B | spotter | Praisy | indexé | 21.36-22.16 | 17 | 3.119 | 04-prezi.wav | 3.337 |
| 07T08-13-36 | B | spotter | Praisy | specifically | 11.60-12.56 | 17 | 3.140 | 04-prezi.wav | 3.400 |
| 06T15-36-12 | B | rescorer | Praisy | Pretty | 0.24-0.56 | 17 | 3.145 | 02-prizzi.wav | 3.387 |
| 04T12-54-09 | B | spotter | Praisy | phrase plus not | 1.84-4.72 | 17 | 3.170 | 10-praise.wav | 3.229 |
| 07T17-39-19 | B | rescorer | Praisy | praise | 2.00-2.48 | 17 | 3.193 | 08-prissyd.wav | 3.455 |
| 07T16-12-33 | B | spotter | Praisy | replaced it with | 1.12-2.08 | 16 | 3.203 | 05-prissy.wav | 3.480 |
| 07T17-05-42 | B | spotter | Praisy | database | 16.32-17.04 | 17 | 3.231 | 10-praise.wav | 3.509 |
| 07T10-23-28 | B | spotter | Praisy | transcription when the | 12.40-14.32 | 17 | 3.257 | 04-prezi.wav | 3.503 |
| 07T14-47-26 | B | spotter | Praisy | through | 21.12-21.60 | 17 | 3.276 | 02-prizzi.wav | 3.456 |
| 04T11-19-17 | B | spotter | Praisy | proprietary | 3.68-4.56 | 17 | 3.282 | 13-prissy.wav | 3.420 |
| 06T12-12-16 | B | spotter | Praisy | Currently | 2.56-3.28 | 17 | 3.311 | 13-prissy.wav | 3.502 |
| 06T14-09-56 | B | spotter | Praisy | vocabulary | 20.08-21.04 | 17 | 3.321 | 13-prissy.wav | 3.495 |
| 06T15-47-25 | B | spotter | Praisy | press ASC during | 10.08-14.32 | 17 | 3.334 | 04-prezi.wav | 3.419 |
| 04T12-54-09 | B | spotter | Praisy | Patrick | 5.52-6.40 | 17 | 3.334 | 10-praise.wav | 3.378 |
| 06T15-47-25 | B | spotter | Praisy | or transcribing | 21.20-22.32 | 17 | 3.341 | 13-prissy.wav | 3.463 |
| 06T14-04-21 | B | spotter | Praisy | explanations | 19.36-20.48 | 17 | 3.353 | 06-prissy.wav | 3.490 |
| 07T08-13-36 | B | spotter | Praisy | was a lot | 28.88-29.28 | 17 | 3.362 | 04-prezi.wav | 3.330 |
| 06T14-12-30 | B | spotter | Praisy | praise | 0.88-1.28 | 17 | 3.374 | 10-praise.wav | 3.560 |
| 07T17-50-00 | B | spotter | Praisy | sentences | 16.24-17.20 | 17 | 3.383 | 04-prezi.wav | 3.251 |
| 07T15-37-32 | B | rescorer | Praisy | praise | 0.40-0.72 | 16 | 3.393 | 15-pressy.wav | 3.583 |
| 07T15-37-24 | B | rescorer | Praisy | praise | 0.96-1.44 | 16 | 3.413 | 01-praisehe.wav | 3.696 |
| 07T17-05-12 | B | rescorer | Praisy | praise | 0.72-1.04 | 17 | 3.416 | 02-prizzi.wav | 3.641 |
| 07T16-09-50 | B | rescorer | Praisy | praise | 0.72-1.04 | 16 | 3.434 | 03-praise.wav | 3.535 |
| 06T13-20-20 | B | spotter | Praisy | person or a | 17.12-17.92 | 17 | 3.442 | 12-pressy.wav | 3.371 |
| 08T17-40-19 | B | rescorer | Praisy | train | 12.72-13.20 | 17 | 3.451 | 09-prissy.wav | 3.555 |
| 08T17-40-19 | B | spotter | Praisy | fast on | 18.72-19.20 | 17 | 3.486 | 03-praise.wav | 3.186 |
| 06T13-20-20 | B | spotter | Praisy | person | 17.12-17.44 | 17 | 3.506 | 07-prissy.wav | 3.481 |
| 08T17-41-18 | B | rescorer | Praisy | train | 3.44-3.84 | 17 | 3.565 | 08-prissyd.wav | 3.529 |
| 08T01-02-23 | B | rescorer | Supabase | update | 1.12-1.60 | 1 | 3.565 | 00-superbase.wav | 3.527 |
| 07T17-39-40 | B | spotter | Vercel | universal | 12.24-12.88 | 6 | 3.041 | 04-versal.wav | 3.336 |
| 04T10-28-14 | B | rescorer | Vercel | merge? | 10.32-11.28 | 7 | 3.142 | 01-versal.wav | 3.284 |
| 08T17-40-19 | B | rescorer | Vercel | level. | 9.84-10.40 | 7 | 3.222 | 00-versailles.wav | 3.340 |
| 07T16-04-42 | B | spotter | Vercel | Versailles | 5.84-6.56 | 6 | 3.253 | 05-versal.wav | 3.317 |
| 06T22-51-48 | B | spotter | Vercel | number of | 5.68-6.24 | 7 | 3.376 | 04-versal.wav | 3.485 |

## Dropped

| clip | group | term | why |
|---|---|---|---|
| 07T17-05-42 | A | Supabase | every exemplar is from this clip |
| 07T17-05-42 | B | Supabase | every exemplar is from this clip |
| 04T10-12-37 | A | Tasmeen | no exemplar for the term |
| 06T14-11-48 | A | Ollama | no exemplar for the term |
| 04T13-15-26 | B | Tasmeen | no exemplar for the term |
| 05T23-00-49 | B | Tasmeen | no exemplar for the term |
| 05T23-00-49 | B | Mirza | no exemplar for the term |
| 06T09-10-32 | B | Mirza | no exemplar for the term |
| 06T11-10-43 | B | Ollama | no exemplar for the term |
| 06T13-20-20 | B | Claude | no exemplar for the term |
| 06T13-20-20 | B | Ollama | no exemplar for the term |
| 06T13-51-22 | B | Redrock | no exemplar for the term |
| 06T14-04-21 | B | Redcrawl | no exemplar for the term |
| 06T14-04-21 | B | Mirza | no exemplar for the term |
| 06T14-11-21 | B | Redcrawl | no exemplar for the term |
| 06T22-51-48 | B | Claude | no exemplar for the term |
| 07T10-23-28 | B | Claude | no exemplar for the term |
| 07T12-35-15 | B | Tasmeen | no exemplar for the term |
| 07T14-47-26 | B | Claude | no exemplar for the term |
| 07T17-39-19 | B | Mirza | no exemplar for the term |
| 07T17-39-40 | B | Claude | no exemplar for the term |
| 08T00-14-39 | B | Redcrawl | no exemplar for the term |
| 08T16-18-00 | B | Arexvy | no exemplar for the term |
