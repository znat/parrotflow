#!/usr/bin/env bash
# Compares the Swift BPE against HuggingFace's own, token by token.
#
#   scripts/check-tokenizer.sh
#
# `BPETokenizer` is hand-written — no swift-transformers, no package
# dependency — and a hand-written BPE goes subtly wrong in ways no example
# catches. tests/tokenizer-cases.json holds what the reference tokenizer
# answers for the byte alphabet, the merge order, NFC, the added tokens and
# the empty string. Regenerate it with scripts/sentence-probe-reference.py.
#
# Reads tokenizer.json only, never the 300 MB model, so it runs on a machine
# that has never dictated. If the model cache has no copy, one is fetched from
# the repository the app fetches from — 2 MB, pinned to a revision. A run that
# cannot get the file fails; it does not pass by skipping.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

CASES="$ROOT/tests/tokenizer-cases.json"
CACHED="$HOME/Library/Application Support/ParrotFlow/models/modernbert-base-64/tokenizer.json"
# Pinned, not `main`. tests/tokenizer-cases.json is the answer for one
# tokenizer.json, so a new one upstream has to fail here rather than quietly
# become the thing being checked.
REVISION=e24392873e55b083638a16a53d13284504fc5f63
URL="https://huggingface.co/znaat/modernbert-coreml/resolve/$REVISION/tokenizer.json"

WORK="$(mktemp -d -t parrotflow-tokenizer)"
trap 'rm -rf "$WORK"' EXIT

if [ -f "$CACHED" ]; then
  export PARROTFLOW_TOKENIZER="$CACHED"
else
  echo "  tokenizer.json is not cached, fetching it"
  if ! curl -fsSL "$URL" -o "$WORK/tokenizer.json"; then
    echo "  ✗ could not fetch $URL"
    exit 1
  fi
  export PARROTFLOW_TOKENIZER="$WORK/tokenizer.json"
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
  got="$("$BIN" --sentence-probe --encode "$text" 2>/dev/null | awk '/^ids/ { print $2 }')"
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
  echo "  ✗ no cases read from tests/tokenizer-cases.json"
  exit 1
fi
printf '  %d/%d  (tests/tokenizer-cases.json)\n' "$pass" "$total"
[ "$pass" = "$total" ]
