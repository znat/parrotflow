# Diagnosing a problem

Start with what needs no permission, then ask before reading anything that
holds the user's words.

## 1. The config

```sh
"$PF" --check-config
```

Common faults it names:

- `✗` on a `command:` that is not executable: `chmod +x` the script.
- `✗` on an `app:` lookahead with no `^`: write `/^(?!.*(a|b))/`.
- `✗` on a step naming a transform that does not exist, or a `when:` with a bare
  word (write `/word/`).
- `⚠ <path>: not a setting`: a typo. The key does nothing. The line suggests
  the key meant.
- A hotkey that another app owns: the menu bar says it failed to register.

A setting that seems to do nothing: compare what the file says with the line
`--check-config` prints for it. An app without `--schema` (`pf.sh` says
`schema=no`) prints no `⚠`, so a misspelt key is silent there. Check the
spelling of each key against the `config_example=` file.

## 2. A sentence

```sh
"$PF" --replace "<what they said>" --app "<App>"
```

If this gives the right answer and the live dictation did not, the difference
is the audio, the app, or a prompt. A step with `app:` needs `--app`.

## 3. The live app: ask first

These hold what the user dictated. Ask before reading them. Report counts and
patterns, never their sentences, unless they ask.

- **The log**, `~/Library/Logs/ParrotFlow.log`: every skipped step and why,
  every model rewrite before and after, and at launch the real Accessibility
  state: `grep "launched —" ~/Library/Logs/ParrotFlow.log | tail -1`.
- **The trace**, `recordings/trace.jsonl` in the config folder: one JSON line per
  dictation, with the decoder's words, timings and confidences, and every
  stage's edits and cost.
- **`--bug-report`** carries the last 50 log lines. Show it to the user before
  anything is shared.

Useful trace queries, run from the `recordings/` folder:

```sh
# How many dictations
jq -r 'select(.kind == "dictation" or .kind == null) | .wav' trace.jsonl | wc -l

# How often each stage changed something
jq -r '.stages[]? | select(.edits and (.edits | length > 0)) | .name' trace.jsonl | sort | uniq -c | sort -rn

# What each stage costs on average
jq -r '.stages[]? | select(.seconds) | [.name, .seconds] | @tsv' trace.jsonl |
  awk -F'\t' '{n[$1]++; s[$1]+=$2} END {for (k in n) printf "%7.3fs  x%-6d %s\n", s[k]/n[k], n[k], k}' | sort -rn

# Why steps were skipped
jq -r '.stages[]? | select(.skip_reason) | .skip_reason' trace.jsonl | sort | uniq -c | sort -rn

# How many words the decoder was unsure of (below 0.5), not which ones
jq -r '[.asr.words[]? | select(.confidence < 0.5)] | length' trace.jsonl | awk '{s+=$1} END {print s}'
```

Lines with `"kind": "correction"` are rules the user taught. Lines with
`"source": "cli"` are re-runs of a clip, not dictation.

## Known causes

| Symptom | Likely cause |
|---|---|
| Last words missing | A Bluetooth microphone. Or `release_tail_seconds` too short. |
| Nothing pasted, text on the clipboard | Focus moved before the text arrived, no field had focus, or no Accessibility. |
| A step never runs | Its `when:` or `app:` did not match. The log names the values. |
| A script changes nothing | No execute bit, a crash, over 2 s, or it prints plain text with `returns: json`. |
| A prompt changes nothing | No model, Ollama not running, or the model name is wrong. It failed open. |
| Chip letter types into the app | Input Monitoring is not granted. |
| Dictation slow | A model step with no condition, or `keep_loaded: false`. Check stage costs above. |
