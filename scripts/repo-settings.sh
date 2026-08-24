#!/usr/bin/env bash
# Whether GitHub's settings for this repository still match settings/repo.yml.
#
#   scripts/repo-settings.sh              # dry run: print the drift, write nothing
#   scripts/repo-settings.sh --check      # the same, and exit 1 if anything differs
#   scripts/repo-settings.sh --apply      # write the intended state, then re-read it
#   scripts/repo-settings.sh --repo o/n   # act on another repository
#
# Dry run is the default, and --apply is the only way this writes anything. The
# order matters more than it looks: settings/repo.yml is edited far more often
# than it is applied, and a script that writes by default turns a typo into a
# live repository change before anyone has read the diff.
#
# Exit codes:
#   0  no drift, or drift printed by a dry run
#   1  --check found drift, or --apply could not write something, or --apply
#      left drift behind — a write the API accepted and did not store reads
#      back unchanged, and that has to be louder than a line of output
#
# A setting this token cannot read or write is printed as a skip and the run
# carries on. That is the normal case in CI: the default GITHUB_TOKEN has no
# `administration` permission, so private vulnerability reporting reads 403.
#
# Needs `gh`, logged in as someone with admin on the repository, and python3
# with pyyaml — the same pair the check scripts already use.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$ROOT/settings/repo.yml"

MODE=dry
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE=apply ;;
    --check) MODE=check ;;
    --repo)  REPO="${2:-}"; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

[ -f "$SETTINGS" ] || { echo "not found: $SETTINGS" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh is not installed: https://cli.github.com" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is not installed" >&2; exit 1; }

if [ -z "$REPO" ]; then
  REPO="${GITHUB_REPOSITORY:-}"
fi
if [ -z "$REPO" ]; then
  REPO="$(git -C "$ROOT" config --get remote.origin.url 2>/dev/null \
          | sed -e 's#^git@github.com:#https://github.com/#' \
                -e 's#^https://github.com/##' -e 's#\.git$##')"
fi
[ -n "$REPO" ] || { echo "cannot tell which repository this is; pass --repo owner/name" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The intended state, flattened to one line per thing. Tab separated, because a
# label description has spaces in it and a topic never has a tab.
python3 -c '
import sys, yaml
s = yaml.safe_load(open(sys.argv[1]))
for k, v in (s.get("repository") or {}).items():
    kind = "bool" if isinstance(v, bool) else "str"
    print("\t".join(["repo", k, kind, ("true" if v else "false") if kind == "bool" else str(v)]))
for t in s.get("topics") or []:
    print("topic\t" + t)
pvr = s.get("private_vulnerability_reporting")
if pvr is not None:
    print("pvr\t" + ("true" if pvr else "false"))
for l in s.get("labels") or []:
    print("\t".join(["label", l["name"], str(l["color"]).lstrip("#").lower(),
                     l.get("description", "")]))
' "$SETTINGS" > "$TMP/plan.tsv" || { echo "cannot read $SETTINGS" >&2; exit 1; }

awk -F'\t' '$1=="repo"'          "$TMP/plan.tsv" > "$TMP/want-repo.tsv"
awk -F'\t' '$1=="topic"{print $2}' "$TMP/plan.tsv" | sort > "$TMP/want-topics.txt"
awk -F'\t' '$1=="label"'         "$TMP/plan.tsv" > "$TMP/want-labels.tsv"
WANT_PVR="$(awk -F'\t' '$1=="pvr"{print $2}' "$TMP/plan.tsv")"

drift=0; skipped=0; failed=0

say_same()    { printf '  ✓ %-30s %s\n' "$1" "$2"; }
say_differs() { drift=$((drift + 1)); printf '  ✗ %-30s %s → %s\n' "$1" "$2" "$3"; }
say_skipped() { skipped=$((skipped + 1)); printf '  ⚠ %-30s skipped: %s\n' "$1" "$2"; }

# Lines on stdin as one space separated line.
oneline() { tr '\n' ' ' | sed 's/ *$//'; }

# api <outfile> <gh api arguments…> — never aborts the run. On failure the
# caller decides whether that is a skip or a failure to write.
api() {
  local out="$1"; shift
  if gh api "$@" > "$out" 2> "$TMP/err"; then
    return 0
  fi
  API_ERROR="$(grep -v '^$' "$TMP/err" | head -1)"
  [ -n "$API_ERROR" ] || API_ERROR="gh api failed"
  return 1
}

# The value of one key in a tab separated file.
field_of() { awk -F'\t' -v k="$2" '$1==k {sub(/^[^\t]*\t/, ""); print; exit}' "$1"; }

# ---------------------------------------------------------------- repository

check_repository() {
  printf '\n==> Repository\n'
  if ! api "$TMP/repo.json" "repos/$REPO"; then
    say_skipped "repository" "$API_ERROR"
    return
  fi
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k, v in d.items():
    if isinstance(v, bool): v = "true" if v else "false"
    elif v is None: v = ""
    elif isinstance(v, (int, float, str)): v = str(v)
    else: continue
    print(k + "\t" + v.replace("\t", " ").replace("\n", " "))
' "$TMP/repo.json" > "$TMP/live-repo.tsv"

  : > "$TMP/changes.tsv"
  local key kind want live
  while IFS=$'\t' read -r _ key kind want; do
    live="$(field_of "$TMP/live-repo.tsv" "$key")"
    if [ "$live" = "$want" ]; then
      say_same "$key" "$want"
    else
      say_differs "$key" "${live:-(unset)}" "$want"
      printf '%s\t%s\t%s\n' "$key" "$kind" "$want" >> "$TMP/changes.tsv"
    fi
  done < "$TMP/want-repo.tsv"

  [ "$MODE" = apply ] || return
  [ -s "$TMP/changes.tsv" ] || return

  python3 -c '
import json, sys
body = {}
for line in open(sys.argv[1]):
    k, kind, v = line.rstrip("\n").split("\t", 2)
    body[k] = (v == "true") if kind == "bool" else v
print(json.dumps(body))
' "$TMP/changes.tsv" > "$TMP/body.json"

  if api "$TMP/patched.json" --method PATCH "repos/$REPO" --input "$TMP/body.json"; then
    printf '  → patched %s\n' "$(cut -f1 "$TMP/changes.tsv" | oneline)"
  else
    failed=$((failed + 1))
    printf '  ⚠ could not patch the repository: %s\n' "$API_ERROR"
  fi
}

# -------------------------------------------------------------------- topics

check_topics() {
  printf '\n==> Topics\n'
  if ! api "$TMP/topics.json" "repos/$REPO/topics"; then
    say_skipped "topics" "$API_ERROR"
    return
  fi
  python3 -c '
import json, sys
for t in json.load(open(sys.argv[1]))["names"]: print(t)
' "$TMP/topics.json" | sort > "$TMP/live-topics.txt"

  local missing extra
  missing="$(comm -23 "$TMP/want-topics.txt" "$TMP/live-topics.txt" | oneline)"
  extra="$(comm -13 "$TMP/want-topics.txt" "$TMP/live-topics.txt" | oneline)"

  if [ -z "$missing" ] && [ -z "$extra" ]; then
    say_same "topics" "$(oneline < "$TMP/want-topics.txt")"
    return
  fi
  drift=$((drift + 1))
  [ -n "$missing" ] && printf '  ✗ %-30s missing: %s\n' "topics" "$missing"
  # PUT replaces the whole list, so anything live and not in the file goes.
  [ -n "$extra" ] && printf '  ✗ %-30s would be removed: %s\n' "topics" "$extra"

  [ "$MODE" = apply ] || return
  python3 -c '
import json, sys
print(json.dumps({"names": [l.strip() for l in open(sys.argv[1]) if l.strip()]}))
' "$TMP/want-topics.txt" > "$TMP/topics-body.json"
  if api "$TMP/topics-out.json" --method PUT "repos/$REPO/topics" --input "$TMP/topics-body.json"; then
    printf '  → topics replaced\n'
  else
    failed=$((failed + 1))
    printf '  ⚠ could not replace the topics: %s\n' "$API_ERROR"
  fi
}

# ------------------------------------------ private vulnerability reporting

check_pvr() {
  [ -n "$WANT_PVR" ] || return 0
  printf '\n==> Private vulnerability reporting\n'
  # Reading this needs admin. A token without it is the normal CI case.
  if ! api "$TMP/pvr.json" "repos/$REPO/private-vulnerability-reporting"; then
    say_skipped "private_vulnerability_reporting" "$API_ERROR"
    return
  fi
  local live
  live="$(python3 -c '
import json, sys
print("true" if json.load(open(sys.argv[1]))["enabled"] else "false")
' "$TMP/pvr.json")"

  if [ "$live" = "$WANT_PVR" ]; then
    say_same "private_vulnerability_reporting" "$live"
    return
  fi
  say_differs "private_vulnerability_reporting" "$live" "$WANT_PVR"

  [ "$MODE" = apply ] || return
  local method=PUT
  [ "$WANT_PVR" = true ] || method=DELETE
  if api "$TMP/pvr-out" --method "$method" "repos/$REPO/private-vulnerability-reporting"; then
    printf '  → %s\n' "$([ "$WANT_PVR" = true ] && echo enabled || echo disabled)"
  else
    failed=$((failed + 1))
    printf '  ⚠ could not change it: %s\n' "$API_ERROR"
  fi
}

# -------------------------------------------------------------------- labels

check_labels() {
  printf '\n==> Labels\n'
  if ! api "$TMP/labels.json" --paginate "repos/$REPO/labels"; then
    say_skipped "labels" "$API_ERROR"
    return
  fi
  # --paginate concatenates one array per page, so read them as a stream.
  python3 -c '
import json, sys
dec = json.JSONDecoder()
text = open(sys.argv[1]).read().strip()
i = 0
while i < len(text):
    page, end = dec.raw_decode(text, i)
    for l in page:
        print("\t".join([l["name"], (l.get("color") or "").lower(),
                         (l.get("description") or "").replace("\t", " ")]))
    i = end
    while i < len(text) and text[i].isspace(): i += 1
' "$TMP/labels.json" > "$TMP/live-labels.tsv"

  # GitHub treats label names case-insensitively, so `bug` and `Bug` are the
  # same label and creating the second one is a 422. Match that: find it
  # regardless of case, then rename it to the case this file names.
  local name color desc live live_name live_color live_desc
  while IFS=$'\t' read -r _ name color desc; do
    live="$(awk -F'\t' -v k="$name" 'BEGIN{k=tolower(k)} tolower($1)==k {print; exit}' "$TMP/live-labels.tsv")"
    if [ -z "$live" ]; then
      drift=$((drift + 1))
      printf '  ✗ %-30s missing\n' "$name"
      [ "$MODE" = apply ] || continue
      if api "$TMP/label-out.json" --method POST "repos/$REPO/labels" \
           -f "name=$name" -f "color=$color" -f "description=$desc"; then
        printf '  → created\n'
      else
        failed=$((failed + 1))
        printf '  ⚠ could not create %s: %s\n' "$name" "$API_ERROR"
      fi
      continue
    fi

    live_name="$(printf '%s' "$live" | cut -f1)"
    live_color="$(printf '%s' "$live" | cut -f2)"
    live_desc="$(printf '%s' "$live" | cut -f3)"
    if [ "$live_name" = "$name" ] && [ "$live_color" = "$color" ] && [ "$live_desc" = "$desc" ]; then
      say_same "$name" "#$color"
      continue
    fi
    drift=$((drift + 1))
    [ "$live_name" = "$name" ]  || printf '  ✗ %-30s named "%s"\n' "$name" "$live_name"
    [ "$live_color" = "$color" ] || printf '  ✗ %-30s #%s → #%s\n' "$name" "$live_color" "$color"
    [ "$live_desc" = "$desc" ]   || printf '  ✗ %-30s "%s" → "%s"\n' "$name" "$live_desc" "$desc"

    [ "$MODE" = apply ] || continue
    # Addressed by the name the repository has, renamed to the one this file
    # has. new_name is a no-op when the two already agree.
    local path
    path="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$live_name")"
    if api "$TMP/label-out.json" --method PATCH "repos/$REPO/labels/$path" \
         -f "new_name=$name" -f "color=$color" -f "description=$desc"; then
      printf '  → updated\n'
    else
      failed=$((failed + 1))
      printf '  ⚠ could not update %s: %s\n' "$name" "$API_ERROR"
    fi
  done < "$TMP/want-labels.tsv"

  # Nothing is deleted here. A label removed from this file stays on the
  # repository, because deleting one strips it from every issue that carries it.
  local unlisted
  cut -f1 "$TMP/live-labels.tsv" | tr '[:upper:]' '[:lower:]' | sort > "$TMP/live-names.txt"
  cut -f2 "$TMP/want-labels.tsv" | tr '[:upper:]' '[:lower:]' | sort > "$TMP/want-names.txt"
  unlisted="$(comm -13 "$TMP/want-names.txt" "$TMP/live-names.txt" | oneline)"
  [ -n "$unlisted" ] && printf '    not in settings/repo.yml, left alone: %s\n' "$unlisted"
  return 0
}

run_pass() {
  drift=0; skipped=0
  check_repository
  check_topics
  check_pvr
  check_labels
}

printf '==> %s   (%s)\n' "$REPO" \
  "$([ "$MODE" = apply ] && echo "applying settings/repo.yml" || echo "reading only, nothing is written")"
run_pass

if [ "$MODE" = apply ]; then
  # Read it all back. This is the half that catches a field the API accepted
  # and did not store, and it is what makes a second run a no-op.
  printf '\n==> Reading it back\n'
  MODE=verify
  run_pass
  printf '\n'
  if [ "$drift" -gt 0 ]; then
    printf '  %d setting(s) still differ after applying. Check them by hand in\n' "$drift"
    printf '  Settings → General: the API accepts some fields it does not store.\n'
  fi
  [ "$skipped" -gt 0 ] && printf '  %d skipped — could not read them back to confirm the write held.\n' "$skipped"
  [ "$failed" -gt 0 ] && printf '  %d write(s) failed.\n' "$failed"
  # Drift, a failed write, or a read-back that could not even be attempted are
  # all a failure, not a note. Exiting 0 for any of them tells a scheduled run,
  # and the person reading the last line, that a setting was confirmed applied
  # when it was not.
  if [ "$drift" -gt 0 ] || [ "$failed" -gt 0 ] || [ "$skipped" -gt 0 ]; then
    exit 1
  fi
  printf '  Done.\n'
  exit 0
fi

printf '\n'
if [ "$drift" -eq 0 ]; then
  printf '  Everything matches settings/repo.yml.\n'
else
  printf '  %d setting(s) differ. Apply them with:\n\n      scripts/repo-settings.sh --apply\n' "$drift"
fi
[ "$skipped" -gt 0 ] && printf '  %d skipped — this token cannot read them. Not counted as drift.\n' "$skipped"

[ "$MODE" = check ] && [ "$drift" -gt 0 ] && exit 1
exit 0
