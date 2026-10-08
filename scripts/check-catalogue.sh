#!/usr/bin/env bash
# Checks the Key column of the skill's feature map against the code.
#
#   scripts/check-catalogue.sh [catalogue.md]
#
# Each backticked span in a Key cell has to be one of:
#   - a top-level config key, or a dotted path from one through coding keys;
#   - a transform or pipeline step field, written `offer:`;
#   - a transform named in built-in/config.example.yaml;
#   - a shipped script, as `dates_fr` names built-in/transforms/dates/fr.py.
# scripts/check-skill.sh walks the dotted paths against --schema. This one
# needs no build, and it is the one that reads the bare names.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" "${1:-$ROOT/skills/parrotflow/references/catalogue.md}" <<'PY'
import pathlib, re, sys, yaml

root, catalogue = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
# Files a user edits, not keys.
allowed = {"vocabulary.yaml"}

swift = (root / "Sources/ParrotFlow/Config.swift").read_text()
enums = []
for body in re.findall(r"enum CodingKeys\b[^{]*\{([^}]*)\}", swift):
    keys = set()
    for cases in re.findall(r"\bcase ([^\n}]*)", body):
        for item in cases.split(","):
            m = re.match(r'\s*(\w+)(?:\s*=\s*"([^"]+)")?', item)
            keys.add(m.group(2) or m.group(1))
    enums.append(keys)
coding_keys = set().union(*enums)
top = next(keys for keys in enums if "hotkey" in keys)
fields = set().union(*(keys for keys in enums if "offer" in keys or "when" in keys))

example = yaml.safe_load((root / "built-in/config.example.yaml").read_text())
transforms = {t["name"] for t in example["transforms"]}


def resolves(span):
    if span in allowed:
        return True
    if span.endswith(":"):
        return span[:-1] in fields
    head, *rest = span.split(".")
    if rest:
        return head in top and all(part in coding_keys for part in rest)
    folder, _, lang = span.rpartition("_")
    return (span in top or span in transforms
            or bool(folder) and (root / "built-in/transforms" / folder / f"{lang}.py").is_file())


column, checked, resolved, bad = None, 0, 0, []
for n, line in enumerate(catalogue.read_text().splitlines(), 1):
    if not line.startswith("|"):
        column = None
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if column is None:
        column = cells.index("Key") if "Key" in cells else -1
        if column < 0:
            bad.append(f"  ✗ {catalogue.name}:{n}: this table has no Key column")
        continue
    if column < 0 or set(cells[0]) <= {"-"}:
        continue
    for span in re.findall(r"`([^`]+)`", cells[column]):
        checked += 1
        if resolves(span):
            resolved += 1
        else:
            bad.append(f"  ✗ {catalogue.name}:{n}: `{span}` is not a top-level config key, a step or"
                       " transform field, a transform in config.example.yaml, or a shipped script")

print("\n".join(bad + [f"  {resolved}/{checked} keys in the Key column resolve"]))
if checked < 30:
    print("  ✗ fewer than 30 keys found")
sys.exit(1 if bad or checked < 30 else 0)
PY
