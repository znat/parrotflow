# Compose a dictation pipeline

A transform defines **what changes**. A pipeline defines **when it runs and in
what order**. Use automatic stages for predictable everyday cleanup; use an
offered action for changes you want to choose each time.

## Understand the order

The decoder finishes a transcript. Fixed sentence-repair and vocabulary passes
run first, followed by your configurable pipeline. Those fixed passes have
their own settings; they are not ordinary steps you can reorder.

The default pipeline includes fillers, date formatting, number formatting,
money formatting, and disfluency cleanup. Order has consequences:

- Dates run before numbers so number formatting does not consume date phrases.
- Money runs after numbers because it reads normalized amounts.
- A PR-link replacement can run after numbers so it sees a numeric reference.

## Add a step without replacing the pipeline

Find `transcription.pipeline` in your existing config. Add the named transform
where it belongs. For example, after configuring your repository in
`github_refs`, add it after the number-formatting step.

Do not paste a two-line example over the entire pipeline. Keep the other
formatting and cleanup steps you want. Defining `github_refs` under
`transforms:` alone does not make it run automatically.

## Conditions

Use `app:` to limit a step to matching applications, and `when:` or `unless:`
to decide whether the step should run for the current text or variables.

The shipped grammar transform could be scoped like this:

```yaml
transcription:
  pipeline:
    - transform: grammar
      app: /slack|outlook/
```

This is an excerpt to merge into your config. It invokes a model and sends text
to that model's configured backend. Consider leaving grammar as an offered
action until you are confident about automatic use.

Conditions see the text as it stands at that point, after earlier transforms.
Structured transforms can publish variables for later conditions to inspect.

[Condition syntax](../pipelines.md#conditions) · [Variables](../pipelines.md#variables) ·
[App matching](../pipelines.md#apps)

## Offered actions are not automatic steps

`offer: true` places a transform on the post-dictation offer. `key:` assigns
its shortcut. This is how Slack mentions can be available without rewriting
every sentence that contains a person's name.

Putting that transform in the pipeline changes the behavior: it becomes
automatic whenever its conditions match. Choose that intentionally.

## Test the complete chain

Test a pipeline fixture with `--pipeline <file> "<text>"`. Add `--app` to test
app conditions, and `--vars` to inspect published values and skipped steps.
Use both examples that should change and examples that should pass through.

After editing the live config, run `--check-config`. A stage that fails or has
no available model must leave the sentence intact.

[CLI walkthrough](cli.md#test-a-pipeline)

## Disable a behavior

Remove its step from your existing pipeline, or change its condition. An empty
`pipeline: []` disables configurable stages; omitting the setting selects the
default instead. The fixed sentence-repair and vocabulary passes have their
own `enabled` settings and are not disabled by an empty list.

## Next

[Build a transform](transforms.md) · [Explore examples](extensions.md) ·
[Full pipeline reference](../pipelines.md) · [All guides](../README.md)
