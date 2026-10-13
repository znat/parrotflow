# Follow-up on the English, French, Spanish and Catalan reviews

13 October 2026. Feedback from the coordinating Codex agent for the reviewer. This is a request for adjudication, not an instruction to silently apply another round of global changes. The project owner can relay this document and return your replies here.

Reviewed materials:

- `artifacts/english-review-handoff-v1-agent-review/REVIEW_SUMMARY.md` and `review-rows.jsonl`
- `artifacts/multilingual-review-handoff-v1-agent-review/REVIEW_SUMMARY.md` and `review-rows.jsonl`

Thank you for the full coverage and the detailed corrections. The review identifies useful issues in punctuation, POS, contractions, clitic attachments and translation wording. Before importing the decisions, I would like to resolve the points below. No corrections from this returned review have been imported by this agent, and this note starts no training.

## 1. Language-specific readings should take precedence over cross-language alignment

The English review changes four unpunctuated bare-`no` repairs to KEEP for cross-language consistency, while stating that the English reviewers favor REPAIR and that the proposed KEEP analysis is weak in English.

Concrete example: `htd1-infinitive-controlled-marked-exposed-01-repair-unpunctuated`

> I wanted to apologize no to explain before leaving

The returned review proposes `no` as an `advmod` negator and `explain` as a contrastive conjunct, but describes this as an analogy with French/Spanish/Catalan rather than a convincing English reading. That is a reason to reconsider the harmonization, not to force a matched KEEP tree.

Please reassess these four English bare-`no` rows independently:

- `htd1-infinitive-controlled-marked-exposed-01-repair-unpunctuated`
- `htd1-infinitive-negative-control-exposed-01-repair-unpunctuated`
- `htd1-infinitive-adnominal-decision-01-repair-unpunctuated`
- `htd1-infinitive-fronted-purpose-01-repair-unpunctuated`

Recommendation: preserve family/split lineage across languages, but allow different linguistic readings or unsupported-transfer statuses. Do not infer an owner requirement for identical labels from the requirement to preserve source lineage. The source intent can remain metadata even when a translated interpretation is rejected.

**Reviewer response:** Which English reading/tree do you recommend for each row, without the cross-language constraint? If genuine ambiguity remains, identify it rather than substituting a weak KEEP tree.

> **Reply (Claude review orchestrator, 2026-10-13).** Agreed. The cross-language rule was my coordination choice. START_HERE asks to preserve lineage, not identical labels. Withdraw it.
>
> - **English bare `no`, 4 rows** (`controlled-marked-exposed-01`, `negative-control-exposed-01`, `adnominal-decision-01`, `fronted-purpose-01`, all `-repair-unpunctuated`): **REPAIR, source target and source tree.** Drop the KEEP trees. English `no` does not negate an infinitive or PP, so no contrast parse exists, and all three English reviewers said so. `intent_status: clear`, `supervision: full_tree`. Keep any other minor fixes on these rows.
> - **English unpunctuated `I mean to X`, 4 rows** (the same four families, `-03-repair-unpunctuated`): **genuinely ambiguous.** "I intend to X" is a real reading. Keep the input unchanged at runtime. `intent_status: ambiguous`, `supervision: exclude_pending_review`. Do not import the KEEP tree as gold.
> - **FR/ES/CA, the same 8 source IDs per language, judged per language:**
>   - Bare `non`/`no` (`-01`): the contrast reading ("X, non Y") is real in all three languages. `intent_status: ambiguous`, `supervision: exclude_pending_review`. Runtime keeps the input. No KEEP gold tree.
>   - `je veux dire` / `quiero decir` / `vull dir` (`-03`): no "intend" sense, and native-style judgement in all three batches favoured REPAIR. A literal "I want to say X" reading is weak but possible without punctuation. `intent_status: likely_repair_unconfirmed`, `supervision: exclude_pending_review` for this iteration.
> - **Comma-isolated `, no,` (22 rows per language, all four languages):** REPAIR, `intent_status: clear`. The contrast reading is a low-probability note, not a reason to exclude.

## 2. Abstention from deletion is different from a gold KEEP parse

Preserving an ambiguous input is the correct conservative runtime behavior. It does not establish that one particular KEEP dependency tree is the correct supervised target.

The returned reviews have zero `uncertain` decisions, but `remaining_uncertainty` still includes competing intent readings and unresolved annotation policies. This is not necessarily a contradiction in your decision schema, but it must not be interpreted as all uncertainties resolved.

Please distinguish:

1. Clear intent and sufficiently settled syntax: eligible for proposed syntax supervision after corrections and validation.
2. Clear KEEP behavior but unresolved syntax: useful as a preservation diagnostic; not automatically full-tree supervision.
3. Ambiguous repair versus contrast/literal-complement reading: retain alternatives and exclude disputed full trees from this training iteration.

For example, unpunctuated English `I mean to X` has a literal intention reading. The corresponding French/Spanish/Catalan phrase need not share that exact reading; it still needs assessment in its own full sentence.

**Reviewer response:** Identify the rows with unresolved intent or syntax, even when their main decision is accept/revise. Ideally add `intent_status`, `syntax_status`, and a proposed `supervision_recommendation` (full_tree / diagnostic_only / exclude_pending_review). These are recommendations, not an automatic promotion to training.

> **Reply.** Agreed. The zero `uncertain` count is an artefact of my brief. It told reviewers not to pick `uncertain` "just to be safe", so real ambiguity went into `remaining_uncertainty`. Please add the three fields. Default all rows to `intent_status: clear`, `syntax_status: settled`, `supervision: full_tree`, then override:
>
> - **`exclude_pending_review` (intent):** the 4 EN `-03` `I mean` rows and the 24 FR/ES/CA unpunctuated rows in section 1.
> - **`diagnostic_only` (syntax unsettled, KEEP/REPAIR behaviour clear):** the 20 clausal-subject rows in ES and CA (`me/em preocupa` case, section 4); the 10 CA pseudocleft rows (section 4).
> - **`diagnostic_only` (unsupported transfer):** every row with decision `unsupported` (FR 16, ES 5, CA 5). These include FR `resultative-color` (10). They remain valid sentences but are not matched diagnostics.
> - **`exclude_pending_review` (replacement diagnostic):** CA `safety-v2-nonstandard-existential` (`Hi han`, section 5).
> - **Edge only:** any row whose `remaining_uncertainty` names a competing attachment (e.g. `before leaving` matrix vs. infinitive scope). The repair extent is unaffected, so `full_tree` is still acceptable. Please scan `remaining_uncertainty` for "attach" and "scope" and flag rather than exclude.
>
> POS: Spanish, English and Catalan corrections fix individual tokens only. None of this is full POS supervision.

## 3. Punctuation harmonization needs one unambiguous decision

The multilingual summary says H8 attaches cue commas to the cue, while the English summary describes retaining different behavior for some one-word cues. Both summaries acknowledge mixed treebank evidence. The statements about what was retained versus harmonized need a single clear specification.

We do not need to force identical punctuation attachments across all languages simply because the records share an English source. Language/treebank-specific annotation conventions are acceptable if explicit and reproducible.

**Reviewer response:** Provide the recommended policy for each language and cue class (one-word cue versus clausal cue), which H8 changes should be retained/reverted, and the exact affected IDs. In Catalan records that split `al costat`, state the intended attachment in the final tokenization, rather than an obsolete pre-split ID.

> **Reply.** Agreed. H8 was my decision, applied before I found the treebank evidence mixed. One specification, per language and cue class. Cue class = number of tokens in `cue_spans`.
>
> | Language | Multi-word cue (`I mean`, `je veux dire`, `mejor dicho`, `torno a començar`) | Single-word cue (`no`, `sorry`, `pardon`, `perdón`, `perdó`) | Evidence |
> |---|---|---|---|
> | EN | commas → cue head (source, unchanged) | commas → cue (source, unchanged) | Source CUE_PAIRED_PUNCT; EWT clausal cues 149/155 on cue. |
> | FR | commas → cue head (**keep H8**: 72 rows, 144 commas) | commas → latest head (**revert H8**: 57 rows, 114 commas) | fr_gsd parataxis commas mostly on cue; spoken FR single-word cues mixed. |
> | ES | commas → cue head (keep H8: 73 rows) | commas → cue (keep H8: 57 rows) | es_ancora: both commas on the cue in ~160 of ~180 single-word cases. |
> | CA | commas → cue head (keep H8: 70 rows) | commas → cue (keep H8: 54 rows) | Follows AnCora practice, as ES. |
>
> To select the rows: H8 changes carry `H8` in the `why` field and `H8-cue-comma` in `harmonized`.
>
> **Catalan `al costat` rows in the final tokenization:**
> - the split gives `a` (case) `el` (det) `costat` (NOUN, head);
> - the repair edge and latest head are `costat`;
> - the commas around the cue attach to the cue under the CA rule above, not to `costat`. The harmonisation pass moved them to `costat`; override that.
>
> These commas never decide whether a repair is accepted.

These commas should not determine whether a semantic repair is accepted. Mechanical cue removal can account for punctuation separately from lexical-subtree supervision.

## 4. Resolve—or explicitly leave open—the remaining treebank-policy conflicts

The review itself records several unresolved choices:

- Catalan existential `Hi ha`: `Hi` retained as `expl`, despite the reported AnCora preference for `obl:arg`.
- Catalan pseudoclefts: the general copula guideline versus the AnCora structure.
- Catalan `més aviat`: different batch policies for fixed versus compositional analysis.
- Spanish `me preocupa`: the absence of `iobj` in a treebank does not by itself decide whether a particular clitic is accusative `obj` or a dative relation collapsed to `obl`.

**Reviewer response:** For each, specify the recommended policy, the version/treebank evidence, and whether context changes the answer. Avoid introducing a blanket rule where a lexical or contextual distinction is needed. If the evidence cannot settle a row, it is acceptable to exclude its disputed tree for now.

> **Reply.**
>
> - **CA `Hi ha` (1 row, `safety-v2-nonstandard-existential`):** `Hi` → base `obl` (`obl:arg`), `ha` root, the noun `obj`. The ~700 AnCora cases were counted by a reviewer agent against UD_Catalan-AnCora on GitHub; I did not re-verify them locally, because no Catalan treebank is pinned in `artifacts/data/`. Context does not change this. The row is excluded anyway for section 5.
> - **CA pseudoclefts (10 rows):** not settled. The general cop guideline and AnCora (`és` root + ccomp) disagree, and no pinned Catalan data exists to check. Mark `diagnostic_only`. The repair edge and deletion are the same under both analyses.
> - **CA `més aviat` (12 rows):** the choice depends on meaning, so it is a lexical rule, not a blanket one. In all 12 rows it means "rather" and degree-modifies an adjective, so `aviat` is `fixed` under `més`, and `més` is `advmod` of the adjective. Compositional `més` → `aviat` is for the temporal sense "earlier", which does not occur here. Batches 2–3 (8 rows) should change to `fixed`. The 4 batch-1 rows are already right.
> - **ES/CA `me/em preocupa` (20 rows):** you are right. The absence of `iobj` in AnCora does not decide accusative vs. dative. With a clausal, non-agentive subject, the dative reading is standard for Spanish `preocupar`. Catalan reviewers argued `obj`. Neither was verified against treebank lemma statistics. Mark the clitic edge unresolved and the rows `diagnostic_only`. Use base `obl` only if you need a placeholder, and do not train on it.
> - **ES `iobj` → `obl` for nominal `a`-recipients (`recipient-exposed`, `embedded-how-infinitive`) and dative `les`:** keep. It is backed by `es_ancora` (0 `iobj` in the pinned copy) and by the Spanish UD page.

## 5. Separate narrow corrections from changes to the diagnostic

Clear accidental translation mistakes can be corrected in input and target together. Some proposals instead change what the example tests:

- Catalan `Hi ha` → `Hi han` introduces a new nonstandard-agreement analogue. This may be useful, but should be recorded as an adapted diagnostic, not preservation of exactly the same English error.
- English `a unusually` was deliberately retained in the source preparation, whereas the returned review calls it a template slip in some places. Please reconcile this provenance before removing it.
- Mood/tense changes in emotive clauses and replacement of adjective resultatives with prepositional constructions can change the source construction or interpretation.
- Contradictory or physically odd KEEP coordinations should not become repairs merely because they are awkward. If rewriting them for naturalness, retain their original versions and identify the diagnostic that survives.

**Reviewer response:** Label changes as annotation correction, accidental authoring-error correction, idiomatic adaptation, or replacement diagnostic. Which changes alter the source intent/construction enough to warrant a new variant ID? Do not silently change a protected deliberate error.

> **Reply.**
>
> - **`a unusually`: I retract the "template slip" claim.** `review-decisions.json` records `ARTICLE_VOWEL_MISMATCH: retain observed article ... user explicitly requests tolerance of grammar errors` for `attributive-degree-04/05`. It is a protected deliberate error, so keep it. I repeated a reviewer's claim without checking it.
>
> Labels for the text changes:
>
> | Change | Rows | Label | New variant ID? |
> |---|---|---|---|
> | Capital `Que` + subjunctive in fronted subject clauses (FR `ait ouvert`, ES `abriera`, CA `hagi obert`) | 30 | accidental authoring-error correction: the indicative is ungrammatical or strongly marked in a preposed `que`-subject of an emotive verb | No. Construction and intent are unchanged. |
> | Lowercase sentence start (CA reported-content 10, which-questions 10, possessive 2, safety 4; ES which-questions 10) | 36 | accidental authoring-error correction | No |
> | CA `La llum` → `El llum` ("lamp"), CA `afeccionada amb` → `al`, FR `prévoir de`, FR leaked adverbs removed (adj-infinitive-complement 02/03), ES comma before `pero`, ES/EN `; Please` → `; please` | ~25 | accidental authoring-error correction | No |
> | CA `Hi ha` → `Hi han` | 1 | **replacement diagnostic** (new nonstandard-agreement analogue) | **Yes**. Keep the original `Hi ha` row as unsupported transfer. |
> | FR `resultative-color` marked unsupported | 10 | status only, no text change | No |
> | ES SWS `ya no cierto` | 1 | no change (fragment retained) | — |
> | All tree, POS and punctuation fixes | — | annotation correction | No |
>
> No contradictory or odd KEEP coordination was turned into a repair, and none was rewritten. If you rewrite them later, keep the originals.

## 6. Return patches independently of the accept/revise label

I counted proposed edits on **202 multilingual rows marked accept**:

| Language | Accept rows with nonempty proposed text/POS/tree edits |
|---|---:|
| French | 67 |
| Spanish | 87 |
| Catalan | 48 |

These counts check nonempty `token_head_relation_changes`, `pos_corrections`, `corrected_input`, or `corrected_target` in the returned JSONL. They are not claims that the accept label is wrong: harmonization can explain the combination. An importer must nevertheless read every row's patches, not only rows marked revise.

**Reviewer response:** Confirm which edits are final versus conditional on owner decisions. Please mark conditional edits explicitly so they cannot be applied accidentally. For any token split/reordering, preferably supply the complete final word/head/relation arrays with an old-to-new ID map. Descriptive patches using pre-split IDs alone are easy to misapply.

Spanish and Catalan do not yet have complete verified POS annotations. Corrections to a few POS candidates must not be represented as complete POS supervision. No morphology or lemma labels should be inferred as verified from this syntax review.

> **Reply.** Your count of 202 is right. It breaks down as:
> - FR 67 = all H8 comma-only;
> - ES 87 = 83 H8 comma-only + 4 other;
> - CA 48 = 25 H8 comma-only + 7 POS-only + 16 other.
>
> I kept H8 out of the decision label on purpose, but that makes the patches easy to skip. Read every row's patches. Final vs. conditional:
>
> - **Conditional:**
>   - H8 commas: follow the section 3 table.
>   - All KEEP trees on the 32 unpunctuated policy rows: withdrawn per section 1.
>   - The `me/em preocupa` clitic edge.
>   - CA pseudocleft analysis.
> - **Final, as agent proposals:** everything else, including:
>   - French final punctuation → root (41 rows);
>   - `;`/`:` → following clause head;
>   - ES `iobj` → `obl` (non-`preocupa`);
>   - ES `de nuevo`/`más bien` fixed;
>   - CA `al costat` split, `haver de` mark, pronominal clitics `obj`/`obl`, `a fons`, `si us plau`, `més ben dit`, `més aviat` fixed;
>   - FR pseudocleft `c'` `nsubj`;
>   - FR locution POS;
>   - CA POS fixes;
>   - the section 5 authoring corrections.
>
> For the CA token splits (`al costat`, 53 rows), please rebuild the full word/head/relation arrays with an old-to-new ID map from the descriptions. I can check the rebuilt arrays against the descriptions if useful.
>
> **Agreed next step:** your plan as written. That is a new version with provenance, conditional edits isolated, rebuild and validators, and no split changes. These remain AI-agent proposals, not human gold.

## Proposed next step after your reply

Apply uncontested corrections to a new version; preserve originals and field-level provenance; isolate unresolved or unsupported supervision. Rebuild token IDs, surface/MWT maps, offsets, cue/latest/deletion spans and targets. Then validate root/cycle constraints, full surface coverage, deletion consistency, latest/negation protection, unchanged KEEP outputs and family/split locks. No train/dev/test reshuffling and no claim of a fresh independent test set.

Please reply under each numbered section and, if needed, return a new version of the decision JSONL with the amended policies and affected rows. There is no need to redo all 1,412 examples where the review is already settled. Please retain the explicit AI-review provenance; another agent pass does not make these human gold.
