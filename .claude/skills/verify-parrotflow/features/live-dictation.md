# Live dictation (user-driven only)

The user holds a hotkey, speaks, and lets go. The app records, decodes, runs
the pipeline, and pastes the text into the frontmost app. This is the product.
**An agent cannot drive it.** It needs a person at the microphone and the
keyboard, and it pastes into whatever is in front. The CLI features in this map
run parts of the same code. None of them proves this path.

## Sub-features

- `live-hotkey` starts recording on press and stops on release (push-to-talk).
- `live-decode` turns the clip into text (speech gate, Parakeet decoder).
- `live-pipeline` runs the user's configured pipeline on the text.
- `live-paste` inserts the result into the focused field of the frontmost app.
- `live-trace` appends one `"source":"live"` row to the variant's `trace.jsonl`.

## How to get to it (user POV)

- ParrotFlow Dev (`/Applications/ParrotFlowDev.app`, bundle id
  `com.parrotflow.app.dev`): hold **Right ⌥ (right Option)**.
  Config `~/.config/parrotflow-dev/`. Log
  `~/Library/Logs/ParrotFlow-Dev.log`.
- ParrotFlow (`/Applications/ParrotFlow.app`, bundle id `com.parrotflow.app`):
  hold **Right ⌘ (right Command)**. Config `~/.config/parrotflow/`. Log
  `~/Library/Logs/ParrotFlow.log`.
- These defaults come from `AppVariant.defaultHotkey` in
  `Sources/ParrotFlow/AppVariant.swift`. `docs/development.md` has them the
  other way round; trust the code. The user's config can override them; read
  it with `grep -A3 '^hotkey:' ~/.config/parrotflow-dev/config.yaml`.

## Driving it with pf.sh

Preconditions:

- `doctor.sh` lists the variant's pid. Note it. Match the log to that pid's
  bundle: `ParrotFlowDev.app` writes `ParrotFlow-Dev.log`, `ParrotFlow.app`
  writes `ParrotFlow.log`.
- Know which code runs. `doctor.sh` prints each installed app's build stamp.
  Compare it with `git rev-parse --short HEAD`. A different stamp means the
  live app does not run this tree; installing is the user's call, never yours.
  A matching stamp proves the commit only. `scripts/build-app.sh` adds
  `-dirty` when the tree had uncommitted changes, and those may not be yours.
  If your change is uncommitted, or the stamp ends in `-dirty`, ask the user
  to confirm the installed app holds it before you claim a live result.
- The user is available and agrees.

- **Record the starting point.** For Dev, run
  `wc -l < ~/Library/Logs/ParrotFlow-Dev.log; wc -l < ~/.config/parrotflow-dev/recordings/trace.jsonl`.
  Write both numbers down.
- **Ask the user.** Send exactly this, for Dev:
  "Please do one dictation for me with ParrotFlow Dev. Open TextEdit and make
  a new empty document with ⌘N. Click inside it. Hold Right Option, say: *um
  we have twenty one users*, then let go. Tell me the exact text that
  appeared. Then close the document without saving."
  For the release app, say ParrotFlow and Right Command instead.
- **Read the log.** With `N` the log count from step one, run
  `tail -n +$((N + 1)) ~/Library/Logs/ParrotFlow-Dev.log | grep -E 'destination:|transcribed:|pipeline:'`.
  Expect a `destination:` line naming TextEdit, a `transcribed:` line, and
  one `pipeline:` line per stage that rewrote or skipped.
- **Read the trace.** With `T` the trace count from step one, run
  `tail -n +$((T + 1)) ~/.config/parrotflow-dev/recordings/trace.jsonl | jq -c 'select(.app.name == "TextEdit") | {source, at, final}'`.
  Expect one row with `"source":"live"`. Its `final` must equal what the user
  reported. With the shipped pipeline that is `We have 21 users.` or close to
  it; the user's own pipeline decides.
- **Proof.** Save the user's reply, the log lines and the `jq` row into the
  run's evidence dir. Say it was a user-driven run.

## Gotchas

- Never type, paste, click or send Apple Events into any app. A probe once
  wiped a Slack draft. Never use `osascript` to read TextEdit either: it
  asks for an Automation grant the user did not give.
- `screencapture` fails: the terminal has no Screen Recording grant. Do not
  run `--panels`; nobody can see it. The user's report is the visual proof.
- Both apps run at once and both write logs. A line in the wrong log proves
  nothing. Match log to pid to bundle, as above.
- The user dictates all day. Filter the trace by `app.name` and by the row
  count you took before. Do not read `tail -1` alone.
- The two traces under `~/Recordings/ParrotFlow*/trace.jsonl` are older and
  no longer written.
- Do not quit, restart, reinstall or signal either app to "get a clean run".
  No `make run`, `make install`, `make stop`, `pkill`, or `kill`.
- If the mic seems stuck, ask the user. Do not touch `UserNotificationCenter`
  or permissions (`make reset-permissions`, `tccutil`).
