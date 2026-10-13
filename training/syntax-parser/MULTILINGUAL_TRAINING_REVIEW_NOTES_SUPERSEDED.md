# Superseded training-plan review notes

Archived verbatim below from the plan. The final reply in [REVIEW_FINAL_RESPONSE.md](REVIEW_FINAL_RESPONSE.md) supersedes conflicting recommendations. Use [the current plan](MULTILINGUAL_TRAINING_PLAN.md) for the active proposal.

---

## Review notes (Claude review orchestrator, 13 October 2026)

Owner decision and review findings for the analyst. The sections above are unchanged; apply these notes when you revise the plan.

### Owner decision: Catalan is out of this campaign

Run English, French and Spanish only. Catalan comes back in a later campaign, once `ca_ancora` is extracted from the same pinned `universal-dependencies/universal_dependencies` revision and audited.

- **Ordinary UD:** 3 languages × 188 batches = **564 updates per epoch**.
- **Hesitation candidates used:** EN/FR/ES only: **688 train, 152 dev, 168 regression test**. The Catalan rows stay in the adjudicated dataset, unused for training.
- **Optional diagnostic:** score the Catalan hesitation dev/test rows zero-shot. Label the result "untrained language", not Catalan support.
- **Stage H at the current 20% design:**
  - 705 updates per epoch;
  - 2,256 hesitation exposures beside 9,000 ordinary ones per epoch (20.04%).

Revised bounded schedule:

| Stage | Runs | Updates per run | New updates total |
|---|---:|---:|---:|
| G1–5 grammar | 2 seeds | 2,820 | 5,640 |
| S1–2 feature screen | 2 arms × 2 seeds | 1,128 | 4,512 |
| S3–5 selected architecture | 2 seeds | 1,692 | 3,384 |
| H6–7 local versus UD control | 2 arms × 2 seeds | 1,410 | 5,640 |
| **Total before NER** | | | **19,176** |

Drop implementation item 1 (Catalan data preparation) from this campaign. NER also targets EN/FR/ES only.

### Checks done

- Update arithmetic in the original plan is correct.
- The hesitation table matches `hesitation-multilingual-adjudicated-v1` exactly. No family crosses splits.
- The adjudication applied the agreed follow-up replies, for example the four English bare-`no` rows are REPAIR again.

### Changes requested before execution

1. **Make the automatic deletion scorer (item 5) a hard prerequisite for Stage H.** H's main gates (no latest-span or negation deletion, no new harmful KEEP deletion) cannot be measured without it. Without it, H spends 5,640 updates to show only that tree support improved.
2. **Hesitation repetition.** Each language has 227–233 training rows from the same 27–29 source families. At 20%, each row is seen about 3.3 times per epoch, about 6.5 times over H. This invites template memorisation (same names, same objects). Either use the 10% ratio from the English run (about 1.6 repeats per epoch), or compare 10% against 20% explicitly. Report dev results per family: dev has only about 13 families.
3. **Spanish repairs are synthetic-only.** Pinned `es_ancora` train has 0 `reparandum` and 5 `discourse` in 14,287 sentences; the Spanish hesitation rows have 120 and 88. Add natural-repair checks to the H gate:
   - French: Rhapsodie and ParisStories;
   - English: ESLSpok;
   - Spanish: **`es_coser-test`, which has 164 natural `reparandum` edges**.

   A drop on these real-speech sets after H means the model learned templates, not repairs.
4. **Latency budget:** resolved. The owner confirmed from earlier experiments that latency is not an issue.
5. **Feature-screen gate.** A +0.20 LAS macro gain over two seeds is within the noise seen in the language-feature run: per-language intervals of about ±0.2–0.3 points, and seed differences up to 0.3. Require the gain to exceed the seed spread.
6. **Minor:** report tokens per language next to sentence counts. AnCora sentences average 31.7 words against 16.3 in EWT, so Spanish gets about twice the tokens per batch.
