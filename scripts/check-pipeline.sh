#!/usr/bin/env bash
# Scores pipeline assembly against tests/pipeline-cases.yaml.
#
#   scripts/check-pipeline.sh
#
# Each case names a fixture in tests/pipelines/, and the fixture carries its own
# languages and replacement table — so this reads no config and scores the same
# on any machine. What it measures is whether stages run when they should, in
# the order given, with conditions reading the text as it stands at that point.
# What the stages themselves do is scored by their own sets.
#
# When a case fails, the stage-by-stage run is printed underneath it: a pipeline
# that produced the wrong string is a question about which stage did it, and the
# finished string cannot answer.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

pass=0; total=0; failed=""

while IFS='|' read -r name fixture app noprompts input expect; do
  [ -z "$name" ] && continue
  total=$((total + 1))
  [ "$expect" = "unchanged" ] && want="$input" || want="$expect"

  # An `app:` case says who was in front. Passed unconditionally: an empty
  # --app is "nothing in front", which is itself a case — an app-conditioned
  # stage has to fail closed — and it avoids an empty array under `set -u`.
  #
  # `no_prompts: true` runs the case the way --replace does. A `replace:`
  # transform must still run there; only a `prompt:` one is held back.
  [ "$noprompts" = "True" ] && off="--no-prompts" || off=""

  path="$ROOT/tests/pipelines/$fixture.yaml"
  if [ ! -f "$path" ]; then
    printf '  ✗ %s\n      no such fixture: tests/pipelines/%s.yaml\n' "$name" "$fixture"
    failed="$failed
      $name"
    continue
  fi

  got="$("$BIN" --pipeline "$path" "$input" --app "$app" $off --quiet 2>/dev/null | tail -1)"

  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ✓ %-52s [%s]\n' "$name" "$fixture"
  else
    failed="$failed
      $name"
    printf '  ✗ %s  [%s]\n      in    %s\n      got   %s\n      want  %s\n' \
      "$name" "$fixture" "$input" "$got" "$want"
    "$BIN" --pipeline "$path" "$input" --app "$app" $off 2>/dev/null | sed 's/^/        /'
  fi
done < <(python3 -c '
import sys, yaml
for c in yaml.safe_load(open(sys.argv[1]))["cases"]:
    print("|".join(str(c.get(k, "")) for k in
                   ("name", "pipeline", "app", "no_prompts", "input", "expect")))
' "$ROOT/tests/pipeline-cases.yaml")

echo
echo "  $pass/$total$failed"
[ "$pass" = "$total" ]
