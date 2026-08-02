# Working on it

The build you are changing and the build you use to get work done are **two
separate applications**. Both can be installed, and both can run at once.

|  | Released | Dev |
| --- | --- | --- |
| App | `ParrotFlow.app` | `ParrotFlowDev.app` |
| Bundle id | `com.parrotflow.app` | `com.parrotflow.app.dev` |
| Hotkey | right ⌥ | right ⌘ |
| Config | `~/.config/parrotflow/` | `~/.config/parrotflow-dev/` |
| Log | `ParrotFlow.log` | `ParrotFlow-Dev.log` |
| Recordings | `~/Recordings/ParrotFlow` | `~/Recordings/ParrotFlow Dev` |
| Menu bar | `mic` | `mic.circle` |

This is not tidiness. macOS grants microphone and Accessibility **per bundle
identifier**, so one identifier for both means every rebuild is revoking and
re-granting permissions on the app you actually rely on — and a half-finished
config change can break it. Separate identifiers make that impossible.

Different hotkeys are what let both run at once: same key and both would record
the same sentence and both paste it. You choose which build hears you by which
key you hold.

## Building

```sh
git clone https://github.com/znat/parrotflow && cd parrotflow
make dev-certificate    # once, so permissions survive rebuilds
make hooks              # once, so commit subjects can cut releases
make install
```

Needs the Xcode command line tools. No Xcode project, no Apple developer
account.

Everything in the Makefile works on the dev build by default:

```sh
make run                  # build and launch ParrotFlow Dev
make logs                 # tail the dev log
make which                # print what this variant resolves to
make stop                 # quit dev; the installed app keeps running

VARIANT=release make logs  # act on the shipped app instead
```

`scripts/variant.sh` is the one place the two identities are defined, and
`AppVariant.swift` is where the app derives its own paths from the identifier it
was built with.

## Releasing

Nobody picks a version number. release-please reads the commit subjects since
the last tag and works it out: a `feat:` bumps the minor, a `fix:` or `perf:`
the patch, and anything else releases nothing at all. It keeps a release PR open
with that version and the changelog it derived, and **merging that PR is the
release** — it tags, builds on a macOS runner, signs, and attaches the archive
that `install.sh` downloads.

So the subject line is not housekeeping. A commit written without a type is
invisible to all of this: no bump, no changelog entry, and no warning that it
was skipped. `make hooks` points git at `.githooks/commit-msg`, which refuses
one before it lands. Run it once per clone — hooks are not cloned.

```
feat:  a capability that was not there before   -> minor
fix:   behaviour that was wrong is now right    -> patch
perf:  same behaviour, measurably faster        -> patch
docs: refactor: test: build: ci: chore:         -> no release
```

The body of the message is unaffected. It is still the place to say what broke
and how you know it is fixed.

```sh
make hooks                       # once per clone
scripts/release-certificate.sh   # once, ever — see the warning in the file
scripts/release.sh               # build the artefacts locally to inspect them
```

Re-running the workflow by hand (Actions → release → Run workflow) recomputes
the release PR. It cannot force a release: with no releasable commits since the
last tag there is nothing to open a PR for.

## Before you push

```sh
scripts/check-default-config.sh   # the config a new install gets still parses
scripts/check-pipeline.sh         # stages, conditions, app gating
scripts/check-dotted.sh           # the one rewrite that fires on ordinary language
scripts/check-numbers.sh          # 97 cases, English and French
scripts/check-routing.sh          # which transform an instruction reaches
```

The full list is in [cli.md](cli.md#the-check-scripts). Anything touching a
prompt or a pattern wants [authoring.md](authoring.md) first — the point of
those sets is that "it looks better" is not a measurement.
