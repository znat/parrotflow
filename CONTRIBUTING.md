# Contribute to ParrotFlow

Bring a workflow you want to improve, a reproducible bug, or an extension others
can reuse. Small changes with clear evidence are easier to review and safer to
ship.

## Pick a starting point

| You want to… | Start here |
| --- | --- |
| Share a replacement, script, or prompt | [Build a transform](docs/guides/transforms.md) |
| Fix or extend the native app | [Development setup](docs/development.md) |
| Understand where a behavior lives | [Architecture guide](docs/guides/architecture.md) |
| Work with a coding agent | [Agent instructions](AGENTS.md) |
| Ask about a workflow before implementing it | [Discussions](https://github.com/znat/parrotflow/discussions) |

A transform with a focused case set makes a useful first contribution. Keep
the implementation and its examples together so another builder can understand
and adapt it.

## Build a separate development app

You need Apple silicon, macOS 15 or later, and the Xcode command line tools.
The default build installs **ParrotFlow Dev**, separate from the released app.

```sh
git clone https://github.com/znat/parrotflow
cd parrotflow
make dev-certificate
make hooks
make install
make test
```

`make dev-certificate` creates a local signing certificate and may ask for your
password. It helps permission grants survive rebuilds. `make install` builds
and installs the dev app; grant that app's permissions separately.

Read [the development guide](docs/development.md) before using reset or
fresh-setup commands. They are not routine prerequisites.

## Test the behavior you changed

`make test` runs the checks that do not need a model, microphone, or screen.
Some checks need additional resources; a passing default suite does not replace
them.

For a prompt or pattern, record the score **before and after** against the same
case set. Include examples that must remain unchanged. Test unavailable models,
script errors, and timeouts: a failure must preserve the transcript.

For UI changes, show the relevant states and transitions. For a bug fix, include
a reproduction and a regression check where practical.

[Authoring and evaluation procedure](docs/authoring.md) · [CLI guide](docs/guides/cli.md)

## Prepare the pull request

Keep the request focused. Explain the behavior, why it should change, and how
you checked it. Include evaluation results for rewrites and screenshots or a
short recording for visual changes. Put lengthy evidence in an expandable
section.

Use a typed commit subject and PR title. The squash-merge title controls release
generation:

| Prefix | Release effect |
| --- | --- |
| `feat:` | Minor release |
| `fix:` or `perf:` | Patch release |
| `docs:`, `refactor:`, `test:`, `build:`, `ci:`, `chore:` | No release |

Sign off each commit:

```sh
git commit -s -m "fix: describe the behavior being corrected"
```

The sign-off certifies the [Developer Certificate of Origin](DCO). Contributions
are made under the project's [GPL-3.0 license](LICENSE). The local hooks and PR
checks enforce the commit conventions.

## Not ready to send code?

A minimal reproduction, a clearer guide, or a realistic keep case for a
transform is useful work too. Use [Discussions](https://github.com/znat/parrotflow/discussions)
for questions that are not bug reports.

[Back to the documentation](docs/README.md)
