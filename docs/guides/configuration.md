# Make ParrotFlow yours

Configuration is a local YAML file, not a separate extension platform. Start
with one setting or one transform. Keep the rest of your working setup intact.

## Edit safely

1. Open **Settings → Edit Config…** from the menu bar.
2. Back up the file before making a substantial change.
3. Edit the existing setting rather than creating a duplicate YAML key.
4. Save; the app reloads the file.
5. Check what the app actually accepted:

```sh
/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow --check-config
```

A YAML file can look reasonable and still contain an unsupported setting.
Treat the validator's output as the result. It also identifies configured
programs and model backends so you can see what will execute.

## Know your files

| File or directory | What belongs there |
| --- | --- |
| `~/.config/parrotflow/config.yaml` | Hotkey, languages, transforms, pipeline, models, feedback, and logging settings. |
| `~/.config/parrotflow/vocabulary.yaml` | Confirmed vocabulary. |
| `~/.config/parrotflow/transforms/<name>/` | Your transform's script, supporting data, and test cases. |
| `~/.config/parrotflow/transforms/built-in/` | App-managed examples, refreshed on launch. |

Use **Settings → Open Config Folder** to find them. Put custom work in your own
transform folder; editing the app-managed built-in copy can lose changes on a
later launch. Development builds use a separate config directory.

## Hotkey

Right Command is the default. Change the existing `hotkey` section if another
key fits your workflow better:

```yaml
hotkey:
  key: right_command
  mode: push_to_talk
```

Avoid a key another app relies on, and be careful with Option keys used to type
accented characters. Supported combinations and timing controls are in the
[hotkey reference](../configuration.md#hotkey).

## Languages

Set the languages you actually dictate in under `transcription.languages`.
English and French have the documented cleanup and formatting support.

```yaml
transcription:
  languages: [en, fr]
```

Merge this into your existing `transcription` section; do not replace that
section with the excerpt. Language selection and formatting are separate:
French date, number, and money scripts must be added to the pipeline if you
want them. Order dates before numbers and money after numbers.

[Language settings](../configuration.md#transcriptionlanguages) ·
[Pipeline guide](pipelines.md)

## Models and privacy

Speech recognition and the built-in local cleanup path do not require a cloud
API key. A prompt transform or interpreted voice command uses a configured
language-model backend.

- **Local:** configure a model served locally, such as through Ollama. Its
  download and memory requirements are separate from the speech model's.
- **Remote:** configure a provider and its credentials. The text processed by
  that command or prompt is sent to that provider.

Choose based on the data you dictate, not only response speed. Treat API keys
as secrets; follow the credential instructions rather than committing a key
to a shared config. Use `--check-config` to inspect the resolved configuration.

[Model and credential reference](../configuration.md#models)

## Logs and recordings

Local processing does not mean nothing is stored. Vocabulary, logs, traces,
and optional audio recordings can contain sensitive material.

Review the existing `logging` settings and `audio.output_dir`. Audio recording
retention is controlled by `logging.audio`; text and timeline logging have
their own controls. Inspect diagnostic output before sharing it.

[Logging reference](../configuration.md#logging) · [CLI diagnostics](cli.md#diagnose-a-problem)

## Extensions

Define what a transform does, then choose whether it runs automatically or on
demand. Do not replace your entire pipeline just to add one transform.

[Explore the examples](extensions.md) · [Build a transform](transforms.md) ·
[Full configuration reference](../configuration.md) · [All guides](../README.md)
