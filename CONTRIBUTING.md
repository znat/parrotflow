# Contributing

Thanks for being here. This page is short on purpose: it says where to start,
how to check your change, and what a commit has to carry.

## Where to start

| You want to | Read |
|---|---|
| Build the app and run it | [docs/development.md](docs/development.md) |
| Write or change a prompt, a table or a script | [docs/authoring.md](docs/authoring.md) |
| Understand what a transcript goes through | [docs/pipelines.md](docs/pipelines.md) |
| Point a coding agent at this repo | [AGENTS.md](AGENTS.md) |

The best first contribution is a transform. One folder under
`examples/transforms/`, with its cases next to it. It is small, it is testable,
and it is what other people copy.

## Build and test

```sh
git clone https://github.com/znat/parrotflow && cd parrotflow
make dev-certificate    # once, so permissions survive rebuilds
make hooks              # once, so commit subjects can cut releases
make install            # builds and installs ParrotFlow Dev, a separate app
make test               # every check that needs no model, mic or screen
```

Needs Apple silicon, macOS 14 or later, and the Xcode command line tools.

`make test` runs the same scripts CI runs. It does not run the sets that need
Ollama (`check-grammar`, `check-routing`, `check-spelling`) or a real screen
(`check-inplace`). If you touched a prompt, run those too — on a machine with
the model — and put the numbers in the pull request.

**Never change a prompt or a pattern without scoring it.** Every rewrite has a
case set and a runner. Get the number before, change one thing, get it after.
The rule and the loop are in [AGENTS.md](AGENTS.md).

## Commits

**The subject decides the release.** Releases and the changelog are computed
from merged subjects, so a subject with no type ships nothing:

```
feat:  a capability that was not there before   -> bumps the minor
fix:   behaviour that was wrong is now right    -> bumps the patch
perf:  same behaviour, measurably faster        -> bumps the patch
docs: refactor: test: build: ci: chore:         -> no release
```

`make hooks` checks this at `git commit`. The pull request title is checked
again on GitHub, because a squash merge takes its subject from the title.

**Sign off every commit.** Add `-s`:

```sh
git commit -s -m "fix: a dictation the decoder returned nothing for is decoded again"
```

That appends one line, `Signed-off-by: Your Name <your@email>`. It means you
certify the [DCO](DCO): the code is yours to give, under this project's
license. A check on every pull request enforces it. Forgot it? Fix the whole
branch with:

```sh
git rebase --signoff main
```

## Pull requests

Keep it to one change. Say what a reviewer should check, and put the numbers in
if you touched a rewrite. Long evidence goes in a `<details>` block, so the
first screen stays readable.

Questions that are not bugs belong in
[Discussions](https://github.com/znat/parrotflow/discussions).
