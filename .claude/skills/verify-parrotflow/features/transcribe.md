# Transcribing a clip

`--transcribe <file.wav>` runs a recorded clip through the full path a
dictation takes after the key comes up: speech gate, decoder, vocabulary pass,
pipeline. It prints the transcript and the timings, and appends one `cli` row
to the trace. It is the closest the CLI gets to live dictation. It still has
no hotkey, no microphone, no paste and no frontmost app.

## Sub-features

- `transcribe-text` prints the transcript between `── transcript ──` rules.
- `transcribe-timing` prints `model load` and `transcribe` seconds with the realtime factor.
- `transcribe-trace` appends one row with `"source":"cli"` to `trace.jsonl` in the config's recordings dir.
- `transcribe-no-vocab` decodes without the vocabulary pass, with `--no-vocab`.

## How to get to it (user POV)

- Live: every dictation runs this path. See [live-dictation.md](./live-dictation.md).
- From a terminal: `.build/release/ParrotFlow --transcribe <file.wav> [--no-vocab]`.

## Driving it with pf.sh

Preconditions:

- **Ask the user first.** It loads the ~1 GB speech model into memory, and the
  user's two live apps already hold a copy each. Go on only after a yes.
- A run is open (`RUN` from `start.sh`).
- The model is on disk: `ls "$HOME/Library/Application Support/FluidAudio/Models"`
  lists `parakeet-tdt-0.6b-v3` and `silero-vad`. If not, stop: the command
  would download it.

- **Make a clip.** Run
  `say -o "$RUN/clip.wav" --data-format=LEI16@16000 --channels=1 "we have twenty one users on super base"`.
  `say -o` writes a file and plays nothing. `afinfo "$RUN/clip.wav"` shows
  `Data format:     1 ch,  16000 Hz, Int16`.
- **Count trace rows before.** Run
  `CFG=$(sed -n 's/^CFG=//p' "$RUN/run.env"); wc -l "$CFG/recordings/trace.jsonl" 2>/dev/null || echo "0 (no trace yet)"`.
  Also note the `## traces` block of `$RUN/state-before.txt`.
- **Transcribe.** Run
  `PF_ALLOW_TRANSCRIBE=1 .claude/skills/verify-parrotflow/scripts/pf.sh "$RUN" transcribe --transcribe "$RUN/clip.wav"`.
  Expect exit `0`, a line `── transcript ─────────────────────────────`,
  the text, and lines starting `model load` and `transcribe`. The exact text
  was not recorded when this map was written; read it, do not assume it.
- **Count trace rows after.** Run the same `wc -l` again. Expect one more row.
  Run `tail -1 "$CFG/recordings/trace.jsonl" | jq -c '{source, wav, final}'`.
  Expect `"source":"cli"` and `wav` set to the full clip path.
- **Proof.** Keep the `.out`, the two row counts, and the `jq` line. Run
  `finish.sh`: it copies `$CFG/recordings/*.jsonl` to
  `$RUN/scratch-recordings/` before it removes the scratch dir. In
  `state-diff.txt`, the `## traces` rows of the four live trace files must not
  gain a `cli` row.

## Gotchas

- The trace and `spans.jsonl` go to `<config dir>/recordings/`, so the scratch
  dir, unless the config sets `audio.output_dir`. Do not set it.
- No redirect for these: one `build: unstamped` line plus the pipeline lines
  in `~/Library/Logs/ParrotFlow.log`; the vocabulary sound pass may rewrite
  `~/Library/Application Support/ParrotFlow/phonemes-multilingual-g2p.json`.
- It starts background loads of the slot model, word vectors and sentence
  model from `~/Library/Application Support/ParrotFlow/models/`. A model
  missing there is downloaded (269 MB, 400 MB, 320 MB). Check that
  `mmbert-small-64`, `qwen3-embedding-0.6b-4bit` and `qwen3-0.6b-base-4bit`
  are present before you run it.
- The default scratch config runs Python transforms on the transcript, like
  `--replace` does.
- `say` voices do not sound like the user. A wrong name here says nothing
  about live accuracy.
