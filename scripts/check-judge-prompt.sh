#!/usr/bin/env bash
# Refuses a judge prompt the judge's own parser cannot read.
#
#   scripts/check-judge-prompt.sh
#
# `VocabularyJudge.prompt` is compiled in, so nothing type-checks it and no
# test exercises it: the model reads it and the reply comes back as prose. The
# one hard link between the prompt and the code is the **shape of the answer**
# — the prompt teaches "a number, then KEEP or REVERT", and
# `VocabularyJudge.verdicts` is written to read exactly that.
#
# Edit the prompt's worked examples into a shape the parser does not read and
# nothing fails. The judge just starts keeping every substitution, because that
# is what an unreadable reply defaults to, and it looks like a worse model
# rather than a broken prompt.
#
# So the examples are fed back through the shipped parser and have to come out
# as the answer they are written to demonstrate. `{terms}` is checked too: the
# stage substitutes it, and a prompt that lost it would silently stop naming
# the user's vocabulary — worth 4 cases of the 74 when it was measured.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

CONFIG="$(mktemp -d -t parrotflow-judge-prompt)"
trap 'rm -rf "$CONFIG"' EXIT
export PARROTFLOW_CONFIG_DIR="$CONFIG"

SWIFT="$ROOT/Sources/ParrotFlow/VocabularyJudge.swift"
pass=0; total=0

check() {
  total=$((total + 1))
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$1"
  else
    printf '  ✗ %s\n      got %s, want %s\n' "$1" "$2" "$3"
  fi
}

prompt="$(python3 - "$SWIFT" <<'PY'
import pathlib, sys
body = pathlib.Path(sys.argv[1]).read_text().split('static let prompt = """', 1)[1]
body = body.split('"""', 1)[0]
lines = body.split("\n")[1:-1]
# A Swift multi-line literal is indented to its closing delimiter, and that
# line is the one this split just dropped. The smallest indent over the
# non-blank lines is the same number and does not depend on the split.
indent = min((len(l) - len(l.lstrip()) for l in lines if l.strip()), default=0)
print("\n".join(l[indent:] if l.strip() else "" for l in lines).strip())
PY
)"

# Every worked answer in the prompt, read by the parser that will read the
# model's. `1. REVERT` in the first example, `1. KEEP` in the second.
answers="$(printf '%s\n' "$prompt" | grep -Eo '^ *[0-9]+\. (KEEP|REVERT)$' | sed 's/^ *//')"
count="$(printf '%s\n' "$answers" | grep -c .)"
check "the prompt shows worked answers" "$count" "2"

while IFS= read -r answer; do
  [ -z "$answer" ] && continue
  want="${answer##*. }"
  check "the parser reads \"$answer\"" "$("$BIN" --verdicts 1 "$answer" 2>/dev/null)" "$want"
done <<< "$answers"

# The stage replaces this. Without it the model is never told which words are
# names, which was worth 4 of the 74 substitutions when it was measured.
case "$prompt" in
  *"{terms}"*) check "the prompt still names the vocabulary" "yes" "yes";;
  *)           check "the prompt still names the vocabulary" "no" "yes";;
esac

echo
if [ "$total" -eq 0 ]; then
  echo "  ✗ no prompt read from VocabularyJudge.swift"
  exit 1
fi
printf '  %d/%d  (VocabularyJudge.prompt)\n' "$pass" "$total"
[ "$pass" = "$total" ]
