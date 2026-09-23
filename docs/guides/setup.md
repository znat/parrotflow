# Install and start dictating

ParrotFlow runs on an Apple-silicon Mac with macOS 15 or later. First launch
downloads the models it needs for local processing. Allow time and disk space
for those downloads; an optional prompt model can require substantially more.

## Install

```sh
brew install znat/tap/parrotflow
```

If you do not use Homebrew, use the installer script:

```sh
curl -fsSL https://raw.githubusercontent.com/znat/parrotflow/main/scripts/install.sh | sh
```

Then open ParrotFlow. Setup walks you through permissions, model downloads,
and any additional setup steps. It may offer eSpeak NG for pronunciation-based
vocabulary support; that is a separate installation, explained before you start it.

## Permissions

Only you can approve macOS permissions. A coding agent cannot grant them.

| Permission | Why ParrotFlow needs it |
| --- | --- |
| Microphone | Record speech while you dictate. |
| Accessibility | Insert text and read selections for correction. |
| Input Monitoring | Catch shortcut letters on the floating offer without typing them into your document. |

Microphone and Accessibility are part of first-time setup. Input Monitoring is
requested when the offer first needs its shortcuts. Approve access for the app
you are using; the released and development builds are separate applications.

## Watch or skip the tour

After the permission and setup steps, the native tour demonstrates contextual
vocabulary and extensions while downloads continue. Examples advance on their
own. Pause, Replay, Back, and Continue let you control the pace.

**Skip tour** goes to setup status. It does not bypass permissions or cancel
downloads. A failed required download takes you to the retry screen. With
Reduce Motion enabled, the tour starts paused with completed examples.

## Try your first dictation

1. Put the caret in a text field.
2. Hold **Right Command**, the default hotkey.
3. Speak, then release the key.
4. Wait for transcription and check the inserted text.

The app stays in the menu bar. Use its Settings menu to change the hotkey,
languages, vocabulary, or transforms. If no suitable destination is available,
check the clipboard and the app's status message.

## Local dictation and optional models

Ordinary local dictation does not need a cloud account or API key. Prompt
transforms and interpreted voice commands use the language model you configure.
They can run locally or use a remote provider; the latter sends input to that
provider. You do not need to configure one just to try dictation.

## If you get stuck

- **No recording:** check Microphone access and the selected input device.
- **Text does not land:** check Accessibility access and the destination field.
- **S or G types into the document:** check Input Monitoring.
- **Models have not arrived:** use the setup status screen and its retry action.
- **A source build appears granted but disagrees:** read the signing guidance
  before resetting permissions. Rebuilds and released updates are not the same.

[Permission diagnostics](../permissions.md) · [Development-build setup](../development.md)

## Next

[Teach your vocabulary](vocabulary.md) · [Explore extensions](extensions.md) ·
[Configure ParrotFlow](configuration.md) · [All guides](../README.md)
