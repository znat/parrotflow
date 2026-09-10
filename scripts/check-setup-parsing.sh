#!/usr/bin/env bash
# Checks what `--setup-parsing` reports and what it would run, against stub
# trees rather than the 170 MB one on this Mac.
#
#   scripts/check-setup-parsing.sh
#
# Nothing here installs anything. Four overrides — PARROTFLOW_PARSING_ROOT,
# PARROTFLOW_PYTHON, PARROTFLOW_REQUIREMENTS, PARROTFLOW_ESPEAK — exist so the
# missing branch, the installed branch and the quoting can be scored without a
# network.
#
# eSpeak NG is stubbed rather than left to the machine. `Phonemes.locate` falls
# through to Homebrew, so on a developer's Mac it is found and on a CI runner it
# is not — and `steps()` counts one more when it is missing. Unstubbed, the step
# counts here pass locally and fail in CI.
#
# The quoting matters more than it looks: the real path is
# `~/Library/Application Support/ParrotFlow/python`, and an unquoted space
# there makes `venv` create two directories and pip read the wrong file.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || BIN="$ROOT/.build/debug/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-parsing)"
trap 'rm -rf "$WORK"' EXIT

pass=0; total=0; failed=""

wants() {
  total=$((total + 1))
  if printf '%s' "$2" | grep -qF -- "$3"; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
  else
    failed="$failed
      $1"
    printf '  ✗ %s\n      want  %s\n      got   %s\n' "$1" "$3" "$2"
  fi
}

exits() {
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
  else
    failed="$failed
      $1"
    printf '  ✗ %s\n      want exit %s, got %s\n' "$1" "$3" "$2"
  fi
}

# A python that answers `import <model>` for whatever is named in MODELS.
stub_tree() {
  local root="$1" models="$2"
  mkdir -p "$root/bin"
  cat > "$root/bin/python3" <<STUB
#!/bin/bash
[ "\$1" = "-c" ] || exit 0
for m in $models; do
  case "\$2" in *"\$m"*) exit 0 ;; esac
done
exit 1
STUB
  chmod +x "$root/bin/python3"
}

run() {
  PARROTFLOW_PARSING_ROOT="$1" \
  PARROTFLOW_PYTHON="$WORK/fake-python3" \
  PARROTFLOW_REQUIREMENTS="$WORK/reqs.txt" \
  PARROTFLOW_ESPEAK="$WORK/fake-espeak" \
  PARROTFLOW_CONFIG_DIR="$WORK/config" \
    "$BIN" --setup-parsing --check 2>/dev/null
}

touch "$WORK/reqs.txt"
printf '#!/bin/bash\nexit 0\n' > "$WORK/fake-python3"; chmod +x "$WORK/fake-python3"
printf '#!/bin/bash\nexit 0\n' > "$WORK/fake-espeak"; chmod +x "$WORK/fake-espeak"

# --- nothing installed ------------------------------------------------------
printf '\nnothing installed\n'
out="$(run "$WORK/absent")"; code=$?
exits "--check exits 1"                 "$code" "1"
wants "espeak comes from the stub, not this Mac" "$out" "✓ eSpeak NG        $WORK/fake-espeak"
wants "python3 is reported missing"     "$out" "✗ python3"
wants "the model is reported missing"   "$out" "✗ en_core_web_sm"
wants "the venv step names PARROTFLOW_PYTHON" "$out" "$WORK/fake-python3' -m venv"
wants "the pip step names the manifest" "$out" "-r '$WORK/reqs.txt'"

# --- a path with a space in it ----------------------------------------------
printf '\na path with a space\n'
out="$(run "$WORK/with space/python")"
wants "the venv target is quoted"       "$out" "-m venv '$WORK/with space/python'"
wants "the interpreter path is quoted"  "$out" "'$WORK/with space/python/bin/python3'"

# --- installed, but one model short -----------------------------------------
printf '\none model short\n'
stub_tree "$WORK/half" "en_core_web_sm"
out="$(run "$WORK/half")"; code=$?
exits "--check still exits 1"           "$code" "1"
wants "the interpreter is found"        "$out" "✓ python3"
wants "the model it has is found"       "$out" "✓ en_core_web_sm"
wants "the missing one is reported"     "$out" "✗ fr_core_news_sm"
wants "only the pip step is left"       "$out" "1 step(s) missing"

# --- everything there -------------------------------------------------------
printf '\neverything there\n'
stub_tree "$WORK/full" "en_core_web_sm fr_core_news_sm"
out="$(run "$WORK/full")"; code=$?
exits "--check exits 0"                 "$code" "0"
wants "it says so"                      "$out" "Nothing to do."
wants "and prints the command: line"    "$out" "$WORK/full/bin/python3 parse.py"

printf '\n%d/%d\n' "$pass" "$total"
[ -n "$failed" ] && printf 'failed:%s\n' "$failed"
[ "$pass" -eq "$total" ]
