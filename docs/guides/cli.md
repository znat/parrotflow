# Test and inspect from the command line

You do not need to record a fresh dictation for every configuration change.
The app's CLI lets you validate settings, run a pipeline on text, and inspect
the result. Use the same commands in your own scripts or with a coding agent.

## Choose the binary

For the installed release:

```sh
PF=/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow
```

For a development build, use
`/Applications/ParrotFlowDev.app/Contents/MacOS/ParrotFlow` instead. Set `PF` to
one of these, not both. A source checkout also has its own built binary.

## Validate configuration

```sh
"$PF" --check-config
```

Read the output, not just the YAML. It reports what survived parsing, the
configured models and commands, and the paths the app resolves. Fix validation
errors before trying to diagnose a dictation.

A terminal permission check can describe the terminal's access rather than
the app's. For Accessibility issues, use the app's launch diagnostics and
[permission guidance](setup.md#permissions).

## Test a pipeline

Keep experiments in a fixture file instead of modifying your live setup.
Fixtures have top-level `transforms:` and `pipeline:` sections, without a
`transcription:` wrapper.

From a repository checkout, run the same replacement shown in the tour:

```sh
"$PF" --pipeline tests/pipelines/onboarding-priorities.yaml \
  "Outage P zero, login P one, polish P two."
"$PF" --pipeline tests/pipelines/onboarding-priorities.yaml \
  "Go up one level."
```

The first result should be `Outage P0, login P1, polish P2.` The second should
be unchanged. A good test checks both the desired change and its boundaries.

For your own fixture, `--app Slack` supplies an app name for conditions, and
`--vars` prints the values stages publish. These commands can execute the
scripts or call the models named by the fixture; inspect it before running it.

## Score an existing transform

```sh
"$PF" --eval grammar
```

This uses the configured transform and its case set. A prompt evaluation needs
its model to be available and may send case inputs to a configured remote
provider. Compare scores before and after a change, including cases that should
remain untouched.

For the onboarding examples in a source checkout:

```sh
bash scripts/check-onboarding.sh
```

That checks timing, example mappings, the priority regex, and the demonstrated
date and money results against shipped scripts. It does not record audio.

## Diagnose a problem

```sh
"$PF" --bug-report
```

Review the report before sharing it. Logs and traces can contain your dictated
text, file paths, or other private details. Include the failing behavior, the
relevant configuration, and a small reproduction rather than uploading an
entire recording directory.

For deeper inspection, the [CLI reference](../cli.md) covers traces, routing,
text insertion diagnostics, and model-specific checks.

## Commands are not all read-only

Teaching vocabulary, seeding a config, setting credentials, and running a
transform can change state. Some diagnostic tools interact with the focused
app or use a microphone. Read the relevant command's contract before running it;
do not treat the complete reference as a checklist to execute.

## Next

[Build a transform](transforms.md) · [Compose a pipeline](pipelines.md) ·
[Complete command reference](../cli.md) · [All guides](../README.md)
