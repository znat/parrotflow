# Build your first transform

Pick one correction you keep making by hand. A good first transform has a
clear input, a clear output, and examples that must remain untouched.
You can write it yourself or work with a coding agent. No app rebuild is needed.

## Choose the smallest tool that fits

| The job | Use |
| --- | --- |
| A known phrase or pattern has a known replacement | `replace:` |
| A lookup, calculation, or branching rule | `command:` |
| A change that needs language judgment | `prompt:` |

Use a replacement or script when it can express the rule. A prompt adds model
availability, latency, and less predictable output; reserve it for a job that
needs those capabilities.

## Work in a fixture first

A test pipeline file has `transforms:` and `pipeline:` at the top level. It is
separate from the live config, where the pipeline lives under `transcription:`.

The tour's [priority fixture](../../tests/pipelines/onboarding-priorities.yaml)
is a complete replacement example. From a repository checkout, run:

```sh
PF=/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow
"$PF" --pipeline tests/pipelines/onboarding-priorities.yaml \
  "Outage P zero, login P one, polish P two."
```

Expected result: `Outage P0, login P1, polish P2.`

Then test a sentence it must leave alone:

```sh
"$PF" --pipeline tests/pipelines/onboarding-priorities.yaml "Go up one level."
```

This is the key habit: a transform is useful only if it changes the right text
and preserves everything else.

## Scripts

A `command:` transform starts a program on your Mac. Only enable code you trust.

The simplest contract is **text on stdin, replacement text on stdout**. Put
diagnostics on stderr. A relative command is resolved in the transform's own
folder, such as `transforms/my_transform/`; keep supporting data beside it.
Give a directly executed script a valid shebang and executable permission.

Use the shipped [Slack mentions source](../../built-in/slack_mentions/slack_mentions.py)
as an example of a lookup. Some transforms use the structured JSON protocol
instead of plain text; declare and implement that protocol together.

Test success, empty input, no match, process failure, and timeout. Failure must
preserve the original transcript, not delete it or return an error as dictation.

[Script contract](../authoring.md#recipe-a-program) ·
[Structured output](../authoring.md#recipe-a-program-that-reports-what-it-did)

## Prompts

A prompt describes a rewrite and uses a configured language model. Start from
the [shipped grammar prompt and cases](../../built-in/transforms/grammar) rather
than assuming one successful sentence proves the behavior.

Choose the backend explicitly. Remote providers receive the text they process.
For automatic prompt stages, add a condition so the model is not called for
every sentence that never needed it. An offered action is often a better first
integration: the user chooses when the rewrite runs.

[Model setup](configuration.md#models-and-privacy) ·
[Prompt reference](../authoring.md#recipe-a-prompt)

## Score before and after

1. Write representative inputs and expected outputs, including keep cases.
2. Measure the current behavior before changing an existing rule or prompt.
3. Make one change and rerun the same set.
4. Investigate regressions, including sentences that should not change.
5. Test unavailable models or failed scripts: the sentence must survive.

For a configured transform with a case set, use `--eval <name>`. The
[authoring reference](../authoring.md#writing-the-case-set) explains case files
and the required checks. Do not improve a score by deleting difficult cases.

## Enable it deliberately

Add the definition to your config, then choose one route:

- **Automatic:** add a step to your existing pipeline, with suitable conditions.
- **Offered:** set `offer: true` and a `key:` so the action appears after dictation.
- **Spoken:** provide a meaningful description and supported spoken invocation.

Save, run `--check-config`, and test again against your actual configuration.
The validator reports the resolved script path; check that it is the file you
intended to run.

[Compose transforms](pipelines.md) · [Test with the CLI](cli.md) ·
[Agent instructions](../../AGENTS.md) · [All guides](../README.md)
