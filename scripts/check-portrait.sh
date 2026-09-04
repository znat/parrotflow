#!/usr/bin/env bash
# What a term's confirmed sentences say, and whether the two tests agree.
#
#   scripts/check-portrait.sh
#
# The floor is read off the term's own uses and never chosen, so the only way
# to see it is to build one and print it. The pair of cases below is the hardest
# term measured: on its own, the portrait gets both of them wrong. Together with
# the slot test they come out right — one left open, one kept as it was heard.
#
# Not in `make test`: it needs the 400 MB word-vector model and the 269 MB
# slot model. Run it by hand after touching TermPortrait or WordVectors.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN=""
for candidate in "$ROOT/.build/release/ParrotFlow" "$ROOT/.build/debug/ParrotFlow"; do
  [ -x "$candidate" ] || continue
  if [ -z "$BIN" ] || [ "$candidate" -nt "$BIN" ]; then BIN="$candidate"; fi
done
[ -n "$BIN" ] || { echo "build first: swift build"; exit 1; }

WORK="$(mktemp -d -t parrotflow-portrait)"
trap 'rm -rf "$WORK"' EXIT
run() { PARROTFLOW_CONFIG_DIR="$WORK" "$BIN" "$@" 2>/dev/null; }
failed=0
check() {
  if printf '%s' "$3" | grep -q "$2"; then printf '  ✓ %s\n' "$1"
  else printf '  ✗ %s: %s\n' "$1" "${3:-no output}"; failed=1; fi
}

out="$(run --portrait Praisy | tail -1)"
check "a term with no uses has no portrait" "no portrait" "$out"

run --learn Precy Praisy --in "Praisy has done great work on the crawler." >/dev/null
run --learn Praise Praisy --in "I asked Praisy to review the migration." >/dev/null
out="$(run --portrait Praisy | tail -1)"
check "two uses and no counter are still too few" "no portrait" "$out"

run --learn Prizy Praisy --in "Praisy wrote the onboarding guide." >/dev/null
# head, not tail: the command lists the sentences under the numbers.
out="$(run --portrait Praisy | head -1)"
check "three uses build one" "^uses 3   tightness 0\..*   floor 0\." "$out"

# The hardest pair measured. The portrait alone is wrong on both.
keep="$(run --portrait Praisy "The review was full of praise." praise | tail -1)"
check "the portrait authorises an ordinary word here" "authorises" "$keep"
slot="$(run --slot-gap "The review was full of praise." praise Praisy | tail -1)"
check "and the slot refuses it, so the two disagree" "refuse" "$slot"

# It used to have no opinion here. `refusal = 0.04` turned that into a refusal:
# 0.716 against a floor of 0.821. This is the one correct write of thirteen that
# the refusal band was measured to cost, and it is this one. The slot says
# nothing, so the gate keeps `Prezi` and the name is not written.
write="$(run --portrait Praisy "Prezi joined the team in March." Prezi | tail -1)"
check "the portrait refuses a real one, which is what the band costs" \
  "refuses" "$write"
slot="$(run --slot-gap "Prezi joined the team in March." Prezi Praisy | tail -1)"
check "and neither does the slot, so it falls through" "no opinion" "$slot"

# One use and one counter-example are a portrait. There is no floor — a
# leave-one-out quantile needs uses to leave out — so the column reads —.
run --for BetterStack "BetterStack paged me again at three." BetterStack >/dev/null
out="$(run --portrait BetterStack | tail -1)"
check "one use and no counter is not one" "no portrait" "$out"
run --against BetterStack "There is no better stack than boring technology." \
  "better stack" >/dev/null
out="$(run --portrait BetterStack | head -1)"
check "one of each builds one, with no floor" \
  "^uses 1   against 1   tightness .*   floor —" "$out"
out="$(run --portrait BetterStack "BetterStack sent a false alarm at midnight." \
  BetterStack | tail -1)"
check "and a sentence like the use is authorised" "authorises" "$out"
out="$(run --portrait BetterStack \
  "I think Node.js and MongoDB is a much better stack than PHP and MySQL." \
  "better stack" | tail -1)"
check "and a sentence like the counter is refused" "refuses" "$out"

# A term with counter-examples is read against them instead of against the
# floor. Three uses about deploying, one about the palace.
run --for Vercel "We deploy the dashboard on Vercel every Friday." Vercel >/dev/null
run --for Vercel "The build is green on Vercel again." Vercel >/dev/null
run --for Vercel "I pushed the site to Vercel this morning." Vercel >/dev/null
run --against Vercel "The palace of Versailles was built for Louis the Fourteenth." \
  Versailles >/dev/null

out="$(run --portrait Vercel "Have you ever walked the grounds at Versailles?" \
  Versailles | tail -1)"
check "one counter turns the floor into a comparison" "^score 0\..*   counters 0\." "$out"

# One counter about the palace is not enough to refuse this one: 0.745 against
# 0.662, so it still authorises. The next two counters turn it round.
run --against Vercel "We toured Versailles in the rain last weekend." Versailles >/dev/null
run --against Vercel "I love visiting the Versailles Castle." Versailles >/dev/null
out="$(run --portrait Vercel "Have you ever walked the grounds at Versailles?" \
  Versailles | tail -1)"
check "and three of them refuse a sentence like the counters" "refuses" "$out"
out="$(run --portrait Vercel "The Vercel deploy hook fired twice this morning." \
  Vercel | tail -1)"
check "a sentence like the uses is authorised" "authorises" "$out"

[ "$failed" -eq 0 ] && echo "Every check passed." || echo "Failed: portrait"
exit "$failed"
