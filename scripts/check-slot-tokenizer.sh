#!/usr/bin/env bash
# Compares the Swift slot tokenizer against HuggingFace's own, token by token.
#
#   scripts/check-slot-tokenizer.sh
#
# `SlotTokenizer` reads mmBERT-small's `tokenizer.json` through
# `swift-transformers`. That file is Gemma-shaped — byte-fallback BPE, a
# `Metaspace` pre-tokenizer writing a space as `▁` — and the ways a reader gets
# it wrong are quiet ones: a missing prefix space, a dropped accent, an empty
# string that comes back as one token. tests/slot-tokenizer-cases.json holds
# what the reference tokenizer answers. Regenerate it with
# scripts/slot-probe-reference.py, which says why the `<mask>` case reads the
# way it does.
#
# Reads the tokenizer files only, never the 269 MB model, so it runs on a
# machine that has never dictated. If the model cache has no copy, they are
# fetched from the repository the app fetches from — pinned to a revision. A run
# that cannot get them fails; it does not pass by skipping.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

CASES="$ROOT/tests/slot-tokenizer-cases.json"
CACHED="$HOME/Library/Application Support/ParrotFlow/models/mmbert-small-64"
# Pinned, not `main`. tests/slot-tokenizer-cases.json is the answer for one
# tokenizer.json, so a new one upstream has to fail here rather than quietly
# become the thing being checked.
REVISION=a983542a6ae292d0147cbdb9b54eddd00c4f6001
BASE="https://huggingface.co/znaat/mmbert-small-coreml/resolve/$REVISION"

WORK="$(mktemp -d -t parrotflow-slot-tokenizer)"
trap 'rm -rf "$WORK"' EXIT

# The whole folder, not one file: `AutoTokenizer.from(modelFolder:)` reads
# config.json and tokenizer_config.json beside tokenizer.json and throws
# without them.
if [ -f "$CACHED/tokenizer.json" ] && [ -f "$CACHED/tokenizer_config.json" ] \
  && [ -f "$CACHED/config.json" ]; then
  export PARROTFLOW_SLOT_TOKENIZER="$CACHED"
else
  echo "  the tokenizer is not cached, fetching it"
  for name in tokenizer.json tokenizer_config.json config.json; do
    if ! curl -fsSL "$BASE/$name" -o "$WORK/$name"; then
      echo "  ✗ could not fetch $BASE/$name"
      exit 1
    fi
  done
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
  got="$("$BIN" --slot-probe --encode "$text" 2>/dev/null | awk '/^ids/ { print $2 }')"
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
  echo "  ✗ no cases read from tests/slot-tokenizer-cases.json"
  exit 1
fi
printf '  %d/%d  (tests/slot-tokenizer-cases.json)\n' "$pass" "$total"
[ "$pass" = "$total" ]
