# CodeRabbit campaign review

13 October 2026. CLI 0.8.0, authenticated outside the execution sandbox. The review used an isolated temporary Git repository containing the new campaign package, its tests and relevant existing source context. No remote was added, no changes were committed to the actual ParrotFlow repository, and no corpus/checkpoint files were submitted. This follows the [local code-review skill](../../.agents/skills/code-review/SKILL.md).

## Review coverage and corrections

| Round | Scope | Result | Disposition |
|---|---|---|---|
| 1 | Full campaign package + tests (13 files) | 1 major, 1 minor | Both fixed |
| 2 | Full package after those fixes | 1 major | Fixed |
| 3 | Runtime-guard fix and regression test | 0 findings | Completed |
| 4 | Additional KEEP safety gate and regression test | Rate limit, no review | Explicitly unreviewed externally |

1. **Dependency fingerprint:** four shared modules used for target definitions, tree behavior and replay now participate in checkpoint compatibility hashes. A regression test mutates each dependency's hash and verifies rejection compatibility changes.
2. **Endpoint consumption order:** source/data checks and required syntax/grammar/NER checkpoint existence precede creation of one-time consumption markers. Missing prerequisites do not burn a heldout evaluation. Errors after reservation remain marked; no automatic retry can silently repeat exposure.
3. **Runtime guard:** the first 20 fresh-epoch updates can stop and save if projected runtime exceeds 10 minutes. An explicitly resumed epoch no longer repeats the same stop every 20 updates. The regression test checks both the initial stop and completion from its saved cursor.

After round 3, a local audit tightened the H gate: equal aggregate harmful-KEEP counts could hide newly damaged sentences. The gate now compares sentence identities and reports each new harmful case. The matching test rejects a model that repairs one previously damaged KEEP but breaks a different KEEP. This final change passed the local suite and integrated CPU/MPS smoke; CodeRabbit returned a quota error before reviewing it. Do not describe the final tree as having an all-files clean external review.

The reviewer is an additional automated check, not proof of experimental validity or model safety. All findings were verified against the implementation before editing.

## Evidence

- [Round 1 observed finding summary](artifacts/campaign-review-v1/round1-summary.json)
- [Round 2 CLI output](artifacts/campaign-review-v1/round2.jsonl)
- [Round 3 CLI output](artifacts/campaign-review-v1/round3.jsonl)
- [Round 4 quota response](artifacts/campaign-review-v1/round4.jsonl)
- [Final code hashes, 43-test result and integrated smoke verification](artifacts/campaign-implementation-verification-v1.json)

The quota response stated a 21-minute wait and no on-demand review availability. No further review, publishing, plan change or workaround was attempted.
