#!/usr/bin/env bash
# Compares the Swift tokenizer against HuggingFace's own, token by token.
#
#   scripts/check-tokenizer.sh
#
# The parser reads parrotflow-syrinx's `tokenizer.json`, which is mmBERT-small's,
# through `ScalarBPE`. That file is Gemma-shaped — byte-fallback BPE, a
# `Metaspace` pre-tokenizer writing a space as `▁` — and the ways a reader gets
# it wrong are quiet ones: a missing prefix space, a dropped accent, an empty
# string that comes back as one token. tests/tokenizer-cases.json holds what the
# reference tokenizer answers. Regenerate it with scripts/tokenizer-reference.py,
# which says why the `<mask>` case reads the way it does.
#
# Reads `tokenizer.json` only, never the model, so it runs on a machine that has
# never dictated. If the parser cache has no copy, it is fetched from the
# repository the app fetches from — pinned to a revision. A run that cannot get
# it fails; it does not pass by skipping.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

CASES="$ROOT/tests/tokenizer-cases.json"
CACHED="$HOME/Library/Application Support/ParrotFlow/models/parrotflow-syrinx"
# Pinned, not `main`: `SyrinxModel.revision`. tests/tokenizer-cases.json is the
# answer for one tokenizer.json, so a new one upstream has to fail here rather
# than quietly become the thing being checked.
REVISION=f3f75830f56901b45069df3492ade0040a6e2e39
BASE="https://huggingface.co/znaat/parrotflow-syrinx-coreml/resolve/$REVISION"
# `SyrinxModel.pinned["tokenizer.json"]`. A cached copy that does not match is
# fetched again rather than scored.
DIGEST=197d4cc5406ee12cc50c8b5511f2393cc32d9db321545979ce041c1199178356

WORK="$(mktemp -d -t parrotflow-tokenizer)"
trap 'rm -rf "$WORK"' EXIT

if [ -f "$CACHED/tokenizer.json" ] \
  && [ "$(shasum -a 256 "$CACHED/tokenizer.json" | awk '{ print $1 }')" = "$DIGEST" ]; then
  export PARROTFLOW_TOKENIZER="$CACHED"
else
  echo "  the tokenizer is not cached at the pinned digest, fetching it"
  if ! curl -fsSL "$BASE/tokenizer.json" -o "$WORK/tokenizer.json"; then
    echo "  ✗ could not fetch $BASE/tokenizer.json"
    exit 1
  fi
  export PARROTFLOW_TOKENIZER="$WORK"
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
  # No `ids` line at all is a tokenizer that did not load, and must not pass
  # as the empty string's answer.
  out="$("$BIN" --tokenize "$text" 2>/dev/null)"
  got="$(printf '%s\n' "$out" | awk '/^ids/ { print $2 }')"
  printf '%s\n' "$out" | grep -q '^ids' || got="(no ids line)"
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
