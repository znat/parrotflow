#!/usr/bin/env bash
# Scores the `dotted` transform against examples/transforms/dotted/cases.txt.
#
#   scripts/check-dotted.sh
#
# The pattern is not written in the case file or in a fixture. It is read out of
# `Config.defaultYAML`, so this scores the rule a new install actually gets — a
# committed copy would be free to drift from the thing that ships, and this is
# the one rewrite that fires on ordinary language rather than on a name someone
# taught it.
#
# Only the transform's own steps are run. The default pipeline also carries
# replacements, fuzzy and numbers, and `numbers` would turn "quinze heures" into
# "15 heures" — a case failing for a reason that has nothing to do with what is
# being measured. The other passes have sets of their own.
#
# `RESIDUE` cases are expected to fail. Two content words either side of the
# word is a shape no stop list distinguishes, and a set that scores 100% by
# omitting what it cannot do is worse than a number.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

FIXTURE="$(mktemp -t parrotflow-dotted).yaml"
CHAT="$(mktemp -t parrotflow-chat).yaml"
DECIMAL="$(mktemp -t parrotflow-decimal).yaml"
trap 'rm -f "$FIXTURE" "$CHAT" "$DECIMAL"' EXIT

python3 - "$ROOT" "$FIXTURE" "$CHAT" "$DECIMAL" <<'PY'
import re, sys, pathlib, yaml

root, out, chat, decimal = (pathlib.Path(a) for a in sys.argv[1:5])
src = (root / "Sources/ParrotFlow/Config.swift").read_text()
start = src.index("static var defaultYAML: String {")
open_quote = src.index('"""', start) + 3
close_quote = src.index('"""', open_quote)
# A Swift literal: interpolations stand in for per-variant values, and an
# escaped backslash is one backslash by the time YAML sees it.
raw = re.sub(r"\\\((.*?)\)", "placeholder", src[open_quote:close_quote]).replace("\\\\", "\\")
doc = yaml.safe_load(raw)

transforms = [t for t in doc.get("transforms") or [] if "replace" in t]
if not any(t["name"] == "dotted" for t in transforms):
    print("  ✗ Config.defaultYAML has no `dotted` transform to score")
    sys.exit(1)

def fixture(steps):
    return yaml.safe_dump({
        "languages": doc["transcription"]["languages"],
        "transforms": transforms,
        "pipeline": [{"transform": name} for name in steps],
    }, allow_unicode=True, sort_keys=False)

out.write_text(fixture(["dotted"]))
# What a chat window gets: the path is built, then wrapped. The wrapping is a
# second table because a rule that does not consume the word after it cannot
# put anything on the far side of it — which is how the first attempt at this
# produced `lis `config.`port`.
chat.write_text(fixture(["dotted", "backticks"]))
# `numbers` before `dotted`, as the shipped pipeline has them. English says
# "three point one four" for a decimal, and it is `numbers` that consumes the
# word — reorder the two and dotted gets there first, turning it into
# "three one.four". Nothing else would notice.
decimal.write_text(fixture(["numbers", "dotted"]).replace(
    "- transform: numbers", "- numbers"))
PY
[ -s "$FIXTURE" ] || exit 1

pass=0; total=0; residue=0; failed=""
while IFS='|' read -r kind input want; do
  case "$kind" in \#*|"") continue;; esac
  case "$kind" in
    CHAT)    use="$CHAT";;
    DECIMAL) use="$DECIMAL";;
    *)       use="$FIXTURE";;
  esac
  got="$("$BIN" --pipeline "$use" "$input" --quiet 2>/dev/null | tail -1)"

  if [ "$kind" = "RESIDUE" ]; then
    residue=$((residue + 1))
    [ "$got" = "$want" ] && printf '  ! %s\n      now passes — move it out of RESIDUE\n' "$input"
    continue
  fi

  total=$((total + 1))
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ✓ %-46s [%s]\n' "$input" "$kind"
  else
    failed="$failed
      $input"
    printf '  ✗ %s  [%s]\n      got   %s\n      want  %s\n' "$kind" "$input" "$got" "$want"
  fi
done < "$ROOT/examples/transforms/dotted/cases.txt"

echo
echo "  $pass/$total   plus $residue known-unfixable$failed"
[ "$pass" = "$total" ]
