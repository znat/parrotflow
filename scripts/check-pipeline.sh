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

while IFS='|' read -r name fixture app noprompts input expect vars; do
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

  # `--vars` prints `var <path> = <value>` for the whole scope before the output
  # line, so the text comparison below is still `tail -1` and a case that says
  # nothing about variables costs nothing to run.
  full="$("$BIN" --pipeline "$path" "$input" --app "$app" $off --quiet --vars 2>/dev/null)"
  got="$(printf '%s' "$full" | tail -1)"

  # Every `expect_vars` entry has to appear, verbatim, in that listing. Absence
  # is a failure and so is a different value — the two are the same question
  # asked of a variable, and a stage that stopped publishing one is exactly the
  # regression this is here to catch.
  missing=""
  if [ -n "$vars" ]; then
    old="$IFS"; IFS=';'
    for pair in $vars; do
      [ -z "$pair" ] && continue
      printf '%s\n' "$full" | grep -qxF "var   $pair" || missing="$missing
      $pair"
    done
    IFS="$old"
  fi

  if [ "$got" = "$want" ] && [ -z "$missing" ]; then
    pass=$((pass + 1))
    printf '  ✓ %-52s [%s]\n' "$name" "$fixture"
  else
    failed="$failed
      $name"
    if [ "$got" != "$want" ]; then
      printf '  ✗ %s  [%s]\n      in    %s\n      got   %s\n      want  %s\n' \
        "$name" "$fixture" "$input" "$got" "$want"
    else
      printf '  ✗ %s  [%s]\n      in    %s\n      variables not as expected:%s\n' \
        "$name" "$fixture" "$input" "$missing"
    fi
    "$BIN" --pipeline "$path" "$input" --app "$app" $off --vars 2>/dev/null | sed 's/^/        /'
  fi
done < <(python3 -c '
import sys, yaml

def printed(value):
    """A value as `Scope.Value.described` writes it, so the two can be compared
    as strings. Strings are quoted there and bare in YAML, which is the only
    difference that matters — and the one a case author would otherwise have to
    remember by writing '"'"'"en"'"'"' in a YAML file."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return "\"%s\"" % value
    return str(value)

for c in yaml.safe_load(open(sys.argv[1]))["cases"]:
    fields = [str(c.get(k, "")) for k in
              ("name", "pipeline", "app", "no_prompts", "input", "expect")]
    fields.append(";".join("%s = %s" % (path, printed(value))
                           for path, value in (c.get("expect_vars") or {}).items()))
    print("|".join(fields))
' "$ROOT/tests/pipeline-cases.yaml")

# --- pipelines that must be refused -----------------------------------------
#
# A config error is only useful if it arrives before a transcript does, so these
# are scored on `--check-config`'s half of `--pipeline`: the fixture is loaded,
# `validate` runs, and the pipeline must be rejected with a message that names
# the actual mistake. A wrong-but-present message fails as loudly as a missing
# one — "it said something" is not the property being tested.
while IFS='|' read -r name fixture problem; do
  [ -z "$name" ] && continue
  total=$((total + 1))
  path="$ROOT/tests/pipelines/refused/$fixture.yaml"

  # An entry with no `expect_problem` is refused rather than run. `grep -F ""`
  # matches every line, so a case with nothing to look for passed on any
  # failure at all — and that is exactly what happened to four cases appended
  # to the wrong section of the file: they named no problem, the fixture did
  # not exist, the binary failed to load it, and the empty pattern called that
  # a pass. A test that cannot fail is worse than no test.
  if [ -z "$problem" ]; then
    failed="$failed
      $name"
    printf '  ✗ %s  [%s]\n      no expect_problem — a refused case must say what it is looking for\n' \
      "$name" "$fixture"
    continue
  fi
  if [ ! -f "$path" ]; then
    failed="$failed
      $name"
    printf '  ✗ %s\n      no such fixture: tests/pipelines/refused/%s.yaml\n' "$name" "$fixture"
    continue
  fi

  if out="$("$BIN" --pipeline "$path" "anything at all" --app "" --quiet 2>&1)"; then
    failed="$failed
      $name"
    printf '  ✗ %s  [%s]\n      was accepted; it should have been refused\n' "$name" "$fixture"
  elif printf '%s' "$out" | grep -qF "$problem"; then
    pass=$((pass + 1))
    printf '  ✓ %-52s [%s]\n' "$name" "$fixture"
  else
    failed="$failed
      $name"
    printf '  ✗ %s  [%s]\n      want  %s\n      got   %s\n' \
      "$name" "$fixture" "$problem" "$out"
  fi
done < <(python3 -c '
import sys, yaml
for c in yaml.safe_load(open(sys.argv[1])).get("refused", []):
    print("|".join(str(c.get(k, "")) for k in ("name", "pipeline", "expect_problem")))
' "$ROOT/tests/pipeline-cases.yaml")

echo
echo "  $pass/$total$failed"
[ "$pass" = "$total" ]
