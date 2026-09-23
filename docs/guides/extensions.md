# Explore the extensions

ParrotFlow turns speech into text. Transforms let you decide what happens next:
format a date, link a ticket, look up a teammate's handle, or run a prompt.
The examples in the demo use these same extension points. They are starting
points for your own workflow, not a fixed menu of capabilities.

## What works out of the box

The default pipeline includes these transforms:

| Transform | Example | How it works |
| --- | --- | --- |
| Fillers | Remove hesitation sounds such as “um” | Replacement tables |
| Dates and times | “nine fifteen AM” → “9:15 AM” | A script |
| Numbers | “two hundred forty-three” → “243” | A script |
| Money | “forty nine dollars and ninety nine cents” → “$49.99” | A script after number normalization |
| Disfluency | “the the prompt” → “the prompt” | Rules, with parsing for some cases |

The English date, number, and money scripts are enabled by default. French
versions also ship; adding a dictation language does not automatically add its
formatting scripts. See [language configuration](configuration.md#languages).

Contextual vocabulary is a separate, fixed pass before the configurable
pipeline. Learn about it in [How vocabulary works](vocabulary.md).

## PR links: your repository, your rules

The shipped `github_refs` definition recognizes references and turns them into
links. It is not enabled in the default pipeline because the repository is yours
to choose.

1. Open your config from **Settings → Edit Config…**.
2. Find `github_refs` and replace `OWNER/REPO` in its URLs.
3. Add `- transform: github_refs` after `numbers_en` in your existing pipeline.
4. Validate and test before using it in everyday dictation.

“PR 478” can then become `#478`, linked to that pull request. Whether a destination
shows a clickable link depends on its support for formatted text insertion.

[Test a pipeline](cli.md#test-a-pipeline) · [Formatted insertion reference](../configuration.md#bullets-bold-and-links)

## Slack mentions: choose when to notify someone

The shipped Slack transform is offered after dictation rather than run on every
sentence. Saying someone's name is not always a request to mention them.

1. Open `transforms/slack_mentions/slack_mentions.py` beside your config.
2. Fill `ROSTER` with the names and handles you actually use.
3. Dictate a message, then press **S** on the post-dictation offer.

The transform replaces matching names with your configured handles. It changes
text; it never sends the message. Check that your destination recognizes the
handle as a mention before relying on it to notify someone.

Until the roster is filled, the offer points you to the setup file. If the
shortcut letter types into your message instead, check
[Input Monitoring](setup.md#permissions).

This is a `command:` transform: it runs a Python script on your Mac. Inspect
scripts before enabling them.

## Grammar

The **G** action runs the configured grammar prompt. Unlike a replacement or a
number-formatting script, it needs a language model. Configure a local backend
or choose a remote provider, understanding that remote prompts send their input
to that provider.

The shipped prompt and its test cases live in
[the grammar folder](../../built-in/transforms/grammar). You can use them as a
starting point; score changes before relying on a modified prompt.

[Configure models](configuration.md#models-and-privacy)

## Build something specific to you

Use a replacement when the change is explicit, a script when it needs logic,
and a prompt when it needs language judgment. Each can be automatic or invoked
on demand. Start small: a ticket link, a project abbreviation, or one recurring
formatting task.

[Build your first transform](transforms.md) · [Compose a pipeline](pipelines.md)

## Inspect the implementation

[Built-in source and test cases](../../built-in/transforms) ·
[Full transform reference](../pipelines.md#transforms) · [All guides](../README.md)
