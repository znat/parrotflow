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
| Recordings | `~/.config/parrotflow/recordings` | `~/.config/parrotflow-dev/recordings` |
| Trace | `~/.config/parrotflow/recordings/trace.jsonl` | `~/.config/parrotflow-dev/recordings/trace.jsonl` |
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

## Testing the setup screen

That screen only appears when there is something to do — a permission that has
never been answered, a model that is not on disk. `make fresh-setup` puts the
build back there: it forgets the grants, deletes the models, removes eSpeak NG,
then builds and launches. It does not ask — it prints each thing as it does
it, so the output is the record of what changed.

```sh
make fresh-setup                      # dev, like everything else here
make fresh-setup ARGS=--config        # move ~/.config/parrotflow-dev aside too
scripts/fresh-setup.sh --help         # the rest of the options
```

Parakeet, Silero VAD and CharsiuG2P live outside the per-build directory, so
both builds read the same copies. The script moves those aside rather than
deleting them, and this run downloads them again. `--purge-old` clears the
copies once that has finished.

`scripts/variant.sh` is the one place the two identities are defined, and
`AppVariant.swift` is where the app derives its own paths from the identifier it
was built with.

## Checking the native onboarding tour

`bash scripts/check-onboarding.sh` checks scene boundaries, vocabulary learning,
Slack's offered action, and every date/time and currency example against the
shipped scripts. It does not record audio, write configuration, or save vocabulary.

Run the built binary with `--panels onboarding 120` to preview the native tour
without resetting permissions or downloading models. `--tutorial-sheet
/tmp/onboarding.png onboarding` renders representative native frames for review.
Use `onboarding:5` instead of `onboarding` for a single zero-based example.
The setup tour advances automatically, supports Pause/Replay/Back, and stops on
the final example while downloads finish. Skip tour goes to the existing setup
status screen; it does not bypass permissions or cancel downloads. Reduced Motion
starts paused and shows completed examples, navigable with Continue.

First-time setup embeds this same native view after required permissions and
the model/eSpeak steps, before the final setup status screen. It also runs when
models are already cached or there are no download rows. A later Finish Setup
revisit does not repeat the tour. The tour uses a fixed 940 × 700 content area;
model progress remains live while its playback is paused. A blocking download
failure routes directly to the existing retry screen, including while paused.
The onboarding check covers the completion/pause/download-failure decision matrix.

### README animation

Export the real native tour without download progress or the interactive footer
(no desktop capture or permission reset). Use an empty temporary directory;
the exporter refuses to overwrite existing frames. It renders at the tour's
actual playback speed.

```sh
frames=$(mktemp -d /private/tmp/parrotflow-readme-XXXXXX)
.build/out/Products/Release/ParrotFlow --onboarding-film "$frames" 20 --highlights
ffmpeg -framerate 20 -i "$frames/frame-%04d.png" -vf scale=940:-1:flags=lanczos \
  -c:v libwebp_anim -quality 75 -compression_level 3 -loop 0 Resources/hero.webp
```

Inspect representative frames before replacing the tracked asset. The WebP loops
about 32 seconds of vocabulary, PR links, Slack mentions, and grammar at 940 × 620
so the side-by-side YAML stays readable. Omit `--highlights` to export the full
tour. The app's interactive tour keeps its controls and its original
940 × 700 window.

## The icons

`Resources/logo.svg` supplies the app icon's voice mark, matching the README
and native `ContextVoiceMark`. The generator places it in lighter lavender on
a dark purple macOS tile and creates every required icon size.

Legacy bird assets still use `Resources/parrot.svg`. Its outline is by
Md Moniruzzaman, from the Noun Project under CC BY; the plumage is the wheel
of `ParrotStyle.swift` run head to tail. The current menu-bar mark is drawn
natively rather than using those legacy images.

```sh
python3 scripts/make-icons.py   # only when the drawing changes
```

That writes `AppIcon.icns` and the legacy menu-bar bird assets, all committed.
The live menu-bar icon is assigned by `AppDelegate` with
`ContextStatusMark.image` for its current state. Icon generation is not part of
the build: an app that cannot compile without a rasteriser working is an app
with one more way to fail.

Two things in there were measured rather than assumed, and both will look like
mistakes until you hit them yourself.

`qlmanage` is the obvious rasteriser and composites onto opaque white. It
reports `hasAlpha: yes` and every pixel of that alpha is `1.0`, which in the
menu bar is a white tile with a bird cut out of it. `scripts/rasterize.swift`
draws through AppKit into a bitmap it allocates, so the background is one we
choose, and it is none.

**Historical notes for the legacy bird assets.** These explain the generated
PNG files, not the current `ContextStatusMark` implementation.

`contentTintColor` looked like the way to
colour a menu bar glyph; set it and AppKit stops applying the template treatment
altogether and draws the image's own pixels, which for a template is solid
black. The old bird implementation therefore baked each colour into its own
file: a template for release, sky for development, and orange for recording.
To change the current menu-bar mark, edit `ContextIdentity.swift`, not these
legacy PNGs.

Colours are chosen from what the menu bar renders, not from what they are: it
washes and lifts everything it is handed, and scarlet came out of it at 7° of
hue, which is a red rather than the orange it was meant to be.

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
scripts/check-pipeline-config.sh  # which pipeline a whole config resolves to
scripts/check-dotted.sh           # the one rewrite that fires on ordinary language
built-in/transforms/numbers/score.py   # 101 cases, one file per language
built-in/transforms/dates/score.py     # 133 cases, dates and clock times
built-in/transforms/money/score.py     # 95 cases, amounts of money
scripts/check-routing.sh          # which transform an instruction reaches
scripts/check-compose.sh          # what a prompt says once the scope is in it
scripts/check-context.sh          # what the context stage publishes for a screen
```

The full list is in [cli.md](cli.md#the-check-scripts). Anything touching a
prompt or a pattern wants [authoring.md](authoring.md) first — the point of
those sets is that "it looks better" is not a measurement.
