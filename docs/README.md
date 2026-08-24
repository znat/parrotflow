# ParrotFlow documentation

Start from the question you have.

## Getting it running

| | |
|---|---|
| [setup.md](setup.md) | The guided install, written to be handed to an agent. Permissions, Ollama, model sizing, and a check that transcription works. |
| [permissions.md](permissions.md) | Microphone, Accessibility, and Input Monitoring: what needs which, and what a rebuild does to the grants. |
| [configuration.md](configuration.md) | Every setting in `config.yaml`, what it does, and what happens when it is wrong. |

## Using it

| | |
|---|---|
| [corrections.md](corrections.md) | Teach it a name — by panel, by spelling it out, or by description. |
| [pipelines.md](pipelines.md) | What a transcript goes through: stages, transforms, conditions, per-app and per-language gates. |
| [cli.md](cli.md) | Every terminal flag. Test a config change without a microphone. |

## Changing it

| | |
|---|---|
| [authoring.md](authoring.md) | **Start here to write a prompt, a table or a script.** The procedure, and the measurement loop that scores it. |
| [development.md](development.md) | Dev and released builds are separate apps. Building, the Makefile, and how to cut a release. |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | Sending a change: `make test`, the commit subject rules, and the sign-off. |
| [architecture.md](architecture.md) | What each file is for, where the time goes, and what the app does not do. |
| [transcription.md](transcription.md) | The speech model, its limits, and the stages that cover them. |
| [distribution.md](distribution.md) | How the app ships, how it is signed, and how updates work. |
| [repo-settings.md](repo-settings.md) | GitHub's own settings for the repository, kept in `settings/repo.yml` and applied from one script. |

---

## If you are an agent

You configure this for someone, or you change a rewrite for them:

1. **Read [authoring.md](authoring.md) first** if the task is a prompt, a
   pipeline, a substitution or a script. It holds the first decision — whether
   the job needs a model at all — and the loop that scores the change.
2. **Validate with the binary, not by reading.** `--check-config` reports what
   the app uses. `--pipeline <file.yaml> "<text>" --app <name>` runs a stage
   against a sentence without a microphone. Both are in [cli.md](cli.md).
3. **Score every change to a prompt or a pattern.** Each rewrite has a case set
   in `tests/` and a runner in `scripts/`. Record the number before and after.
4. **Fail open.** A stage that fails must leave the transcript as it arrived.
   To check this, stop Ollama and run the pipeline again.
5. **Say what a `command:` transform runs.** Config that executes code needs a
   clear statement to the person who owns the machine.

If you install rather than configure, read [setup.md](setup.md). It is written
for you, and you must follow it in order.
