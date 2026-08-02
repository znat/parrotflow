# ParrotFlow documentation

Start from the question you have.

## Getting it running

| | |
|---|---|
| [setup.md](setup.md) | The guided install, written to be handed to an agent. Permissions, Ollama, model sizing, and a check that transcription works before it hands over. |
| [permissions.md](permissions.md) | Microphone and Accessibility: what needs which, and why a rebuilt app loses its grants. |
| [configuration.md](configuration.md) | Every setting in `config.yaml`, what it does, and what happens when it is wrong. |

## Using it

| | |
|---|---|
| [corrections.md](corrections.md) | Teaching it a name — by panel, by spelling it out, or by describing the change. |
| [pipelines.md](pipelines.md) | The reference for what a transcript goes through: stages, transforms, conditions, per-app and per-language gating. |
| [cli.md](cli.md) | Every terminal flag. How to test a config change without speaking into a microphone. |

## Changing it

| | |
|---|---|
| [authoring.md](authoring.md) | **Start here to write a prompt, a table or a script.** The procedure, with the measurement loop that says whether you improved it. |
| [development.md](development.md) | Dev and released builds are separate apps. Building, the Makefile, and how a release is cut. |
| [architecture.md](architecture.md) | What each file is for, where the time goes, and what the app deliberately does not do. |

## Why it is built this way

| | |
|---|---|
| [transcription.md](transcription.md) | Why Parakeet and not Whisper, why it cannot be prompted, and what covers that instead. |
| [distribution.md](distribution.md) | Why this ships by curl rather than Homebrew, what notarization would change, and how updates work. |

---

## If you are an agent

Configuring this for someone, or changing a rewrite on their behalf:

1. **Read [authoring.md](authoring.md) first** if the task is a prompt, a
   pipeline, a substitution or a script. It contains the decision that the rest
   of the work hangs on — whether the job wants a model at all — and the loop
   that proves the change was an improvement.
2. **Validate with the binary, not by reading.** `--check-config` reports what
   the app would actually use; `--pipeline <file.yaml> "<text>" --app <name>`
   runs a stage against a sentence without a microphone. Both in
   [cli.md](cli.md).
3. **Never change a prompt or a pattern without scoring it.** Every rewrite has
   a case set in `tests/` and a runner in `scripts/`. Record the number before
   and after; a change that cannot be measured has not been shown to help.
4. **Fail open.** A stage that errors must leave the transcript exactly as it
   arrived. Check it by killing Ollama and running the pipeline again.
5. **Say what a `command:` transform runs.** Config that executes code is worth
   naming out loud to the person whose machine it will run on.

Installing rather than configuring: [setup.md](setup.md) is written for you,
step by step, and expects to be followed in order.
