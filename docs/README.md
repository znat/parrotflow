# ParrotFlow documentation

Use dictation as it ships, then make it fit your vocabulary and workflow.
Start with a focused guide. Open the technical references when you need the
complete contract, an edge case, or the implementation details.

## Get to your first useful result

1. [Install and start dictating](guides/setup.md) — requirements, permissions,
   downloads, the tour, and your first sentence.
2. [Teach your vocabulary](guides/vocabulary.md) — correct a name, understand
   context, and recover from an unwanted edit.
3. [Explore extensions](guides/extensions.md) — what ships enabled, what needs
   setup, and how PR links, Slack mentions, and grammar work.

## Make it yours

| Your next task | Guide |
| --- | --- |
| Change a hotkey, language, model, or logging setting | [Configuration](guides/configuration.md) |
| Write a replacement, script, or prompt | [Build your first transform](guides/transforms.md) |
| Choose when transforms run and in what order | [Compose a pipeline](guides/pipelines.md) |
| Test a sentence or diagnose a problem | [Command-line tools](guides/cli.md) |
| Understand the architecture and find the code | [How it fits together](guides/architecture.md) |

A good first extension solves one correction you keep making by hand.
Test sentences it should change and sentences it should leave alone before
enabling it in everyday dictation.

## Build and contribute

The development app has its own identity and configuration so you can keep
using the release while changing the source.

[Build the dev app](development.md) · [Contribute a change](../CONTRIBUTING.md) ·
[Ask a question](https://github.com/znat/parrotflow/discussions)

## Technical references

These pages retain the detailed settings, protocols, diagnostics, and measured
behavior. They are references to consult, not a sequence to read before using
the app.

- [Configuration reference](configuration.md) — every setting and its behavior.
- [Pipeline reference](pipelines.md) — stages, conditions, variables, and transform contracts.
- [CLI reference](cli.md) — flags, evaluation, tracing, and insertion diagnostics.
- [Authoring procedure](authoring.md) — the scoring loop and detailed recipes.
- [Correction reference](corrections.md) — vocabulary teaching and editing edge cases.
- [Permissions](permissions.md) — access checks, signing, and rebuilds.
- [Architecture reference](architecture.md) — source map, insertion safeguards, and timings.
- [Transcription](transcription.md) — recognition, vocabulary matching, and evaluation.
- [Development](development.md) — builds, native previews, and the README animation.
- [Distribution](distribution.md) — signing, installation, and updates.
- [Repository settings](repo-settings.md) — how repository configuration is maintained.

## Working with a coding agent

Start the agent at [AGENTS.md](../AGENTS.md). Give it a concrete behavior and
examples, including cases that must not change.

The agent should validate with the actual binary, score an existing rewrite
before and after changing it, and test failure behavior. A `command:` transform
executes a program; it should explain what that program runs before enabling it.

For an agent-assisted installation, use [the setup procedure](setup.md).
Permission approvals and the final spoken dictation test still need you.

[Back to ParrotFlow](../README.md)
