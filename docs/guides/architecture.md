# How ParrotFlow fits together

ParrotFlow separates speech recognition from the changes you want to make to
the resulting text. You can extend a workflow without rebuilding audio capture
or asking a general-purpose language model to rewrite every sentence.

## One dictation, from keypress to text

1. **Capture.** The hotkey starts recording from your selected microphone.
2. **Transcribe.** After release, the finished clip is processed by the local
   speech model.
3. **Repair and vocabulary.** Fixed passes use the decoder's output and context
   to handle supported sentence repairs and vocabulary candidates.
4. **Transform.** Your pipeline runs in order, checking conditions before each
   stage and passing the result to the next.
5. **Insert.** The app writes to the destination or copies the result. Offered
   actions let you request another transform afterward.

The onboarding's progressive text is an illustration of speaking. Actual
dictation processes a finished clip; it is not live streaming transcription.

## Where to extend it

| Layer | What you own | Start here |
| --- | --- | --- |
| Vocabulary | Your terms, heard forms, and confirmed context | [Vocabulary](vocabulary.md) |
| Replacements | A table or regex describing an explicit change | [Transforms](transforms.md) |
| Scripts | A program and supporting data | [Script contract](transforms.md#scripts) |
| Prompts | Instructions and a selected model backend | [Prompt transforms](transforms.md#prompts) |
| Pipeline | Order and conditions for automatic stages | [Pipelines](pipelines.md) |

Config and vocabulary are local files. Scripts and their data live in named
transform folders. Built-in examples are inspectable, but keep your custom
versions outside the app-managed built-in directory.

## Local processing and explicit boundaries

Speech recognition and the local cleanup path run on your Mac after model
downloads. Prompt transforms can use a local or remote model. A remote backend
receives the input needed for that operation; “local dictation” is not a promise
that a custom remote transform never sends data.

A script runs with the access available to its process. It can do more than
replace text, including making network requests if you write it that way. Inspect
code and configuration before enabling extensions from someone else.

Logs, traces, and optional audio recordings can retain sensitive content locally.
Review [configuration and logging](configuration.md#logs-and-recordings).

## Preserve the sentence when something fails

A missing model, failed script, or timeout must not lose the transcript. A stage
that cannot complete should leave its input unchanged. This is why transform
tests need failure cases as well as successful rewrites.

Text insertion has its own safeguards. Reading a selection, moving it, and
writing back are separate operations; an app can acknowledge a request without
having applied it yet. The insertion code checks the destination and result
rather than assuming every request succeeded.

Undo targets the field that was changed and checks whether its text has moved
on. It is a safety mechanism for the recent operation, not a general edit history.

## Why the kind of transform matters

A replacement is string work. A script adds process startup and whatever work
the program performs. A prompt adds a model call, potentially including model
loading. Use conditions and on-demand actions to avoid work a sentence does not
need. Measure on your own machine rather than treating one timing as universal.

## Find your way into the code

| Responsibility | Source |
| --- | --- |
| App lifecycle and integration | [AppDelegate.swift](../../Sources/ParrotFlow/AppDelegate.swift) |
| Audio capture | [Recorder.swift](../../Sources/ParrotFlow/Recorder.swift) |
| Speech recognition | [Transcriber.swift](../../Sources/ParrotFlow/Transcriber.swift) |
| Pipeline execution | [Pipeline.swift](../../Sources/ParrotFlow/Pipeline.swift) |
| Configuration | [Config.swift](../../Sources/ParrotFlow/Config.swift) |
| Native onboarding | [NativeOnboardingView.swift](../../Sources/ParrotFlow/NativeOnboardingView.swift) |

The [architecture reference](../architecture.md) has the fuller source map,
insertion behavior, and timing measurements. The
[development guide](../development.md) explains how to build a separate dev app
without replacing the release you use.

[Contribute](../../CONTRIBUTING.md) · [All guides](../README.md)
