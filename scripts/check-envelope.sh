#!/usr/bin/env bash
# What a `returns: json` command is handed, against `--envelope-schema`, and
# built-in/runner/envelope.py against the schema.
#
#   scripts/check-envelope.sh                  what this build sends without models
#   scripts/check-envelope.sh --record <home>  also rewrites tests/envelopes/
#
# Without the models, as on CI, the binary sends no parse and no readings, and
# --pipeline has no trace. Those envelopes are recorded fresh on every run. The
# parse, the vectors and the readings need the models, so they are recorded
# once from a home that has them (a copy, never your own) and kept in
# tests/envelopes/. Every text is invented. `trace` comes only with a
# dictation (`--transcribe` loads the 1 GB speech model), so it is checked
# against envelope.py here and not against recorded bytes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-envelope)"
trap 'rm -rf "$WORK"' EXIT
RECORD=""
if [ "${1:-}" = --record ]; then
  RECORD="${2:?usage: check-envelope.sh --record <home with the models>}"
  export HOME="$RECORD" CFFIXED_USER_HOME="$RECORD"
else
  export HOME="$WORK/home" CFFIXED_USER_HOME="$WORK/home"
fi
export PARROTFLOW_CONFIG_DIR="$WORK/config"
mkdir -p "$HOME/Library/Logs" "$PARROTFLOW_CONFIG_DIR/transforms" "$WORK/out"

"$BIN" --envelope-schema > "$WORK/schema.json" || { echo "  ✗ --envelope-schema failed"; exit 1; }

STEPS="plain parse vectors readings"
for name in $STEPS; do
  mkdir -p "$PARROTFLOW_CONFIG_DIR/transforms/$name"
  cat > "$PARROTFLOW_CONFIG_DIR/transforms/$name/$name.py" <<'PY'
#!/usr/bin/env python3
import os, sys
name = os.path.splitext(os.path.basename(sys.argv[0]))[0]
with open(os.path.join(os.environ["ENVELOPE_OUT"], name + ".json"), "w") as f:
    f.write(sys.stdin.read())
print("{}")
PY
  chmod +x "$PARROTFLOW_CONFIG_DIR/transforms/$name/$name.py"
done
cat > "$PARROTFLOW_CONFIG_DIR/steps.yaml" <<'YAML'
languages: [en]
transforms:
  - { name: plain, description: d, command: plain.py, returns: json }
  - { name: parse, description: d, command: parse.py, returns: json, parse: true }
  - { name: vectors, description: d, command: vectors.py, returns: json, parse: vectors }
  - { name: readings, description: d, command: readings.py, returns: json, readings: true }
YAML
fixture() {  # fixture <steps> -> run.yaml
  { cat "$PARROTFLOW_CONFIG_DIR/steps.yaml"; echo "pipeline:"
    for name in $1; do echo "  - transform: $name"; done; } > "$PARROTFLOW_CONFIG_DIR/run.yaml"
}
record() {  # record <dir> <steps> <text> [--warm]
  mkdir -p "$WORK/$1"; fixture "$2"
  ENVELOPE_OUT="$WORK/$1" "$BIN" --pipeline "$PARROTFLOW_CONFIG_DIR/run.yaml" "$3" ${4:+"$4"} \
    > "$WORK/$1.log" 2>&1 < /dev/null || { echo "  ✗ --pipeline failed:"; tail -5 "$WORK/$1.log"; exit 1; }
}

BOUNDARY="We shipped the build. Then we tested it on Friday."
record bare "$STEPS" "$BOUNDARY"
record flat readings "we shipped the build on friday"
cp "$WORK/bare/plain.json" "$WORK/out/plain.json"
if [ -z "$RECORD" ]; then
  cp "$WORK/bare/parse.json" "$WORK/out/parse-missing.json"
  cp "$WORK/bare/vectors.json" "$WORK/out/vectors-missing.json"
  cp "$WORK/bare/readings.json" "$WORK/out/readings-missing.json"
fi
cp "$WORK/flat/readings.json" "$WORK/out/readings-none.json"

if [ -n "$RECORD" ]; then
  record warm "parse vectors readings" "$BOUNDARY" --warm
  mkdir -p "$ROOT/tests/envelopes"
  for name in parse vectors readings; do cp "$WORK/warm/$name.json" "$ROOT/tests/envelopes/$name.json"; done

  echo "  recorded tests/envelopes/: parse, vectors, readings"
fi

python3 "$ROOT/scripts/check-envelope.py" "$WORK/schema.json" "$ROOT/built-in/runner/envelope.py" \
  "$WORK"/out/*.json "$ROOT"/tests/envelopes/*.json
