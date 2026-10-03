#!/usr/bin/env bash
# Checks the public `parrotflow` skill in skills/parrotflow/ against the binary.
#
#   scripts/check-skill.sh
#
# The skill is read by agents on Macs that have the app and not this
# repository, so every key, flag and file it names has to be real:
#
#   1. a backticked key path (`audio.microphones`) is in `--schema`, and is not
#      a deprecated key outside a "Retired" section;
#   2. a YAML block shaped like config.yaml gets no unknown-key warning, and
#      one shaped like vocabulary.yaml uses only keys the parser reads;
#   3. every --flag is one the binary handles;
#   4. scripts/pf.sh runs and prints what SKILL.md reads from it;
#   5. metadata.app_version matches the release and carries the marker;
#   6. the references SKILL.md routes to exist, and each one is routed to;
#   7. the starter in assets/transform/ loads and scores 100% with --eval.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/skills/parrotflow"
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

WORK="$(mktemp -d -t parrotflow-skill)"
trap 'rm -rf "$WORK"' EXIT
CFG="$WORK/cfg"
mkdir -p "$CFG"

pass=0; total=0; failed=""

check() {
  local name="$1" got="$2" want="$3"
  total=$((total + 1))
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
    printf '  ✓ %s\n' "$name"
  else
    failed="$failed
      $name"
    printf '  ✗ %s\n      got   %s\n      want  %s\n' "$name" "$got" "$want"
  fi
}

PARROTFLOW_CONFIG_DIR="$CFG" "$BIN" --schema > "$WORK/schema.json" 2> /dev/null
check "--schema runs" "$?" "0"

# --- 1. key paths ----------------------------------------------------------------

python3 - "$WORK/schema.json" "$SKILL" > "$WORK/paths.txt" <<'PY'
import json, pathlib, re, sys

schema = json.load(open(sys.argv[1]))
root = schema["properties"]
skill = pathlib.Path(sys.argv[2])
top = "|".join(sorted(root, key=len, reverse=True))
path_re = re.compile(rf"^((?:{top})(?:\.[A-Za-z_][A-Za-z0-9_]*)+)(?=$|[:\s])")


def resolve(node, parts):
    """The node a path names, and whether it went through a deprecated key."""
    deprecated = False
    for part in parts:
        if node.get("deprecated"):
            deprecated = True
        options = [node] + node.get("anyOf", []) + node.get("oneOf", [])
        nxt = None
        for o in options:
            if part in o.get("properties", {}):
                nxt = o["properties"][part]
                break
            if isinstance(o.get("items"), dict) and part in o["items"].get("properties", {}):
                nxt = o["items"]["properties"][part]
                break
        if nxt is None:
            for o in options:
                extra = o.get("additionalProperties")
                if isinstance(extra, dict):
                    nxt = extra
                    break
                if extra is None and "properties" not in o and o.get("type") in ("object", ["object", "null"]):
                    return o, deprecated
        if nxt is None:
            return None, deprecated
        node = nxt
    return node, deprecated or bool(node.get("deprecated"))


seen = 0
for md in sorted(skill.rglob("*.md")):
    heading = ""
    for n, line in enumerate(md.read_text().splitlines(), 1):
        if line.startswith("#"):
            heading = line
        for span in re.findall(r"`([^`\n]+)`", line):
            m = path_re.match(span)
            if not m:
                continue
            seen += 1
            parts = m.group(1).split(".")
            node, deprecated = resolve({"properties": root}, parts)
            where = f"{md.relative_to(skill)}:{n}"
            if node is None:
                print(f"{where}: {m.group(1)} is not in --schema")
            elif deprecated and "retired" not in heading.lower():
                print(f"{where}: {m.group(1)} is deprecated")
print(f"paths {seen}")
PY
out="$(cat "$WORK/paths.txt")"
printf '%s\n' "$out" | grep -v '^paths ' | sed 's/^/      /'
check "every backticked key path is a current key" \
  "$(printf '%s\n' "$out" | grep -vc '^paths ')" "0"
check "and there are enough of them to mean something" \
  "$(printf '%s\n' "$out" | sed -n 's/^paths //p' | awk '{print ($1 >= 30) ? "yes" : $1}')" "yes"

# --- 2. config-shaped YAML blocks ----------------------------------------------

python3 - "$WORK/schema.json" "$SKILL" "$WORK/blocks" <<'PY'
import pathlib, re, sys

skill, out = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
out.mkdir()
count = 0
for md in sorted(skill.rglob("*.md")):
    block, start = None, 0
    for n, line in enumerate(md.read_text().splitlines(), 1):
        if block is None and line.strip() == "```yaml":
            block, start = [], n
        elif block is not None and line.strip() == "```":
            # A config excerpt: top-level keys, and not a fixture or a case file.
            keys = {m.group(1) for l in block if (m := re.match(r"^([A-Za-z_][\w-]*):", l))}
            if keys and not keys & {"languages", "pipeline", "cases", "terms"}:
                count += 1
                d = out / f"{count:03d}"
                d.mkdir()
                (d / "config.yaml").write_text("\n".join(block) + "\n")
                (d / "where").write_text(f"{md.relative_to(skill)}:{start}")
            block = None
        elif block is not None:
            block.append(line)
PY
blocks=0; warned=0
for dir in "$WORK"/blocks/*/; do
  blocks=$((blocks + 1))
  warnings="$(PARROTFLOW_CONFIG_DIR="$dir" "$BIN" --check-config 2> /dev/null | grep ' ⚠ .*not a setting')"
  if [ -n "$warnings" ]; then
    warned=$((warned + 1))
    printf '      %s\n' "$(cat "$dir/where")" "$warnings"
  fi
done
check "no config-shaped YAML block has an unknown key" "$warned" "0"
check "and there are such blocks" "$([ "$blocks" -ge 10 ] && echo yes || echo "$blocks")" "yes"

# --- 2b. vocabulary.yaml blocks ----------------------------------------------------

# The app ignores an unknown key in vocabulary.yaml in silence, so the keys are
# checked against the parser's own CodingKeys. Above the term, only `terms:`:
# every other key there is retired or has moved to config.yaml.
python3 - "$ROOT/Sources/ParrotFlow/Config.swift" "$SKILL" > "$WORK/vocab.txt" <<'PY'
import pathlib, re, sys, yaml

swift = pathlib.Path(sys.argv[1]).read_text()
term_keys = set(re.search(r"enum CodingKeys: String, CodingKey \{ case (floor[^}]*)\}", swift)
                .group(1).replace(" ", "").split(","))
said_keys = set(re.search(r"case (heard, phonemes[^\n]*)", swift)
                .group(1).replace(" ", "").split(","))
term_keys.discard("heard")  # the old spelling of `pronunciations:`

count = 0
for md in sorted(pathlib.Path(sys.argv[2]).rglob("*.md")):
    block = None
    for n, line in enumerate(md.read_text().splitlines(), 1):
        if block is None and line.strip() == "```yaml":
            block, start = [], n
        elif block is not None and line.strip() == "```":
            doc = yaml.safe_load("\n".join(block))
            if isinstance(doc, dict) and "terms" in doc:
                count += 1
                where = f"{md.relative_to(sys.argv[2])}:{start}"
                for key in set(doc) - {"terms"}:
                    print(f"{where}: `{key}:` is not read from vocabulary.yaml")
                for term, entry in (doc["terms"] or {}).items():
                    for key in set(entry or {}) - term_keys:
                        print(f"{where}: `{key}:` on {term} is not a term key")
                    for said in (entry or {}).get("pronunciations") or []:
                        for key in set(said if isinstance(said, dict) else {}) - said_keys:
                            print(f"{where}: `{key}:` is not a pronunciation key")
            block = None
        elif block is not None:
            block.append(line)
print(f"blocks {count}")
PY
out="$(cat "$WORK/vocab.txt")"
printf '%s\n' "$out" | grep -v '^blocks ' | sed 's/^/      /'
check "every vocabulary.yaml key the skill writes is one the parser reads" \
  "$(printf '%s\n' "$out" | grep -vc '^blocks ')" "0"
check "and the skill has vocabulary blocks" \
  "$(printf '%s\n' "$out" | sed -n 's/^blocks //p' | awk '{print ($1 >= 1) ? "yes" : $1}')" "yes"

# --- 3. flags ---------------------------------------------------------------------

# Flags that belong to other programs, not to ParrotFlow.
not_ours="--no-wall-clock --greedy"
unknown=""
flags="$(cat "$SKILL"/SKILL.md "$SKILL"/references/*.md | grep -oE -- '--[a-z][a-z0-9-]+' | sort -u)"
for flag in $flags; do
  case " $not_ours " in *" $flag "*) continue ;; esac
  grep -q -- "\"$flag\"" "$ROOT"/Sources/ParrotFlow/*.swift || unknown="$unknown $flag"
done
check "every --flag the skill names is one the binary handles" "${unknown# }" ""
check "and the skill names the flags it relies on" \
  "$(for f in --check-config --schema --replace --eval --pipeline; do
       printf '%s\n' "$flags" | grep -qx -- "$f" || printf '%s ' "$f"; done)" ""

# --- 4. pf.sh ----------------------------------------------------------------------

pf="$(PARROTFLOW_BIN="$BIN" PARROTFLOW_CONFIG_DIR="$CFG" bash "$SKILL/scripts/pf.sh")"
check "pf.sh exits 0" "$?" "0"
value() { printf '%s\n' "$pf" | sed -n "s/^$1=//p"; }
check "pf.sh prints only key=value lines" \
  "$(printf '%s\n' "$pf" | grep -cvE '^[a-z_]+=')" "0"
check "pf.sh names the binary it was given" "$(value binary)" "$BIN"
check "and the config folder" "$(value config)" "$CFG/config.yaml"
check "and says this binary has --schema" "$(value schema)" "yes"
for key in variant config_dir built_in app_version skill_version version_match; do
  check "pf.sh prints $key" "$(printf '%s\n' "$pf" | grep -c "^$key=")" "1"
done

# --- 5. the version --------------------------------------------------------------

release="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["."])' "$ROOT/.github/.release-please-manifest.json")"
check "metadata.app_version is the released version" "$(value skill_version)" "$release"
check "and carries the release-please marker" \
  "$(grep -c '^  app_version: .*x-release-please-version' "$SKILL/SKILL.md")" "1"
check "release-please rewrites SKILL.md" \
  "$(grep -c '"skills/parrotflow/SKILL.md"' "$ROOT/.github/release-please-config.json")" "1"

# --- 6. references ----------------------------------------------------------------

named="$(grep -oE 'references/[a-z-]+\.md' "$SKILL/SKILL.md" | sort -u)"
missing=""; for ref in $named; do [ -f "$SKILL/$ref" ] || missing="$missing $ref"; done
check "every reference SKILL.md names exists" "${missing# }" ""
orphans=""
for file in "$SKILL"/references/*.md; do
  printf '%s\n' "$named" | grep -qx "references/$(basename "$file")" || orphans="$orphans $(basename "$file")"
done
check "every reference is named in SKILL.md" "${orphans# }" ""

# --- 7. the starter transform ------------------------------------------------------

PARROTFLOW_CONFIG_DIR="$CFG" "$BIN" --check-config > /dev/null 2>&1
mkdir -p "$CFG/transforms/starter"
cp "$SKILL/assets/transform/transform.py" "$CFG/transforms/starter/starter.py"
cp "$SKILL/assets/transform/cases.yaml" "$CFG/transforms/starter/cases.yaml"
check "the starter script is executable" \
  "$([ -x "$SKILL/assets/transform/transform.py" ] && echo yes)" "yes"
cat >> "$CFG/config.yaml" <<'YAML'
  - name: starter
    description: spoken arrow keys as arrow symbols
    command: starter.py
    returns: json
YAML
PARROTFLOW_CONFIG_DIR="$CFG" "$BIN" --check-config > "$WORK/starter-check.txt" 2> /dev/null
check "a config with the starter loads" "$?" "0"
check "and names it as a program" \
  "$(grep -c '"starter" runs a program' "$WORK/starter-check.txt")" "1"
PARROTFLOW_CONFIG_DIR="$CFG" "$BIN" --eval starter > "$WORK/starter-eval.txt" 2> /dev/null
check "the starter scores 100% on its own cases" \
  "$(grep -E '^  overall' "$WORK/starter-eval.txt" | grep -oE '[0-9]+%')" "100%"

echo
echo "  $pass/$total$failed"
[ "$pass" = "$total" ]
