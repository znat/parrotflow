#!/usr/bin/env bash
# Compares the parser's tokenizer, `ScalarBPE`, against HuggingFace's own,
# token by token.
#
#   scripts/check-parser-tokenizer.sh
#
# `ScalarBPE` reads mmBERT-small's `tokenizer.json` byte by byte: added tokens
# on the raw text, `▁` for a space, then byte-fallback BPE over scalars. The
# ways it can go wrong are quiet ones: a missing prefix space, a dropped
# accent, an empty string that comes back as one token.
# tests/parser-tokenizer-cases.json holds what the reference tokenizer answers.
#
# Reads `tokenizer.json` only, never the model. If the model cache has no copy,
# it is fetched from the repository the app fetches from, pinned to a revision.
# A run that cannot get it fails; it does not pass by skipping.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

CASES="$ROOT/tests/parser-tokenizer-cases.json"
CACHED="$HOME/Library/Application Support/ParrotFlow/models/parrotflow-syrinx-fp16"
# The revision SlotModel pins.
REVISION=fcf309cf35dad30cbbb92ddfb3f3c09a5961fd87
BASE="https://huggingface.co/znaat/parrotflow-syrinx-coreml/resolve/$REVISION"

WORK="$(mktemp -d -t parrotflow-parser-tokenizer)"
trap 'rm -rf "$WORK"' EXIT

if [ -f "$CACHED/tokenizer.json" ]; then
  export PARROTFLOW_SLOT_TOKENIZER="$CACHED"
else
  echo "  the tokenizer is not cached, fetching it"
  if ! curl -fsSL "$BASE/tokenizer.json" -o "$WORK/tokenizer.json"; then
    echo "  ✗ could not fetch $BASE/tokenizer.json"
    exit 1
  fi
  export PARROTFLOW_SLOT_TOKENIZER="$WORK"
fi

# Text and ids on two lines per case, so a case holding a newline or a quote
# arrives whole. The ids are compared as text: same order, same count.
if ! python3 -c '
import json, sys
for case in json.load(open(sys.argv[1])):
    print(json.dumps(case["text"]))
    print(",".join(str(i) for i in case["ids"]))
' "$CASES" > "$WORK/cases"; then
  echo "  ✗ $CASES could not be read"
  exit 1
fi

pass=0; total=0
while IFS= read -r quoted && IFS= read -r want; do
  total=$((total + 1))
  text="$(python3 -c 'import json,sys; sys.stdout.write(json.loads(sys.argv[1]))' "$quoted")"
  # `ids` with nothing after it is the empty string's answer, and `$2` is then
  # empty. That is a pass, not a missing line.
  got="$("$BIN" --parse --encode "$text" 2>/dev/null | awk '/^ids/ { print $2 }')"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$quoted"
  else
    printf '  ✗ %s\n' "$quoted"
    printf '      want  %s\n' "$want"
    printf '      got   %s\n' "$got"
  fi
done < "$WORK/cases"

echo
if [ "$total" -eq 0 ]; then
  echo "  ✗ no cases read from tests/parser-tokenizer-cases.json"
  exit 1
fi
printf '  %d/%d  (tests/parser-tokenizer-cases.json)\n' "$pass" "$total"
[ "$pass" = "$total" ]
