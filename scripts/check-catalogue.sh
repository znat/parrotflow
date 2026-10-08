#!/usr/bin/env bash
# Checks the Key column of the skill's feature map against the code.
#
#   scripts/check-catalogue.sh [catalogue.md]
#
# Each backticked span in a Key cell has to be one of:
#   - a Config.swift coding key, or a dotted path made only of them;
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
coding_keys = set()
for body in re.findall(r"enum CodingKeys\b[^{]*\{([^}]*)\}", swift):
    for cases in re.findall(r"\bcase ([^\n}]*)", body):
        for item in cases.split(","):
            m = re.match(r'\s*(\w+)(?:\s*=\s*"([^"]+)")?', item)
            coding_keys.add(m.group(2) or m.group(1))

example = yaml.safe_load((root / "built-in/config.example.yaml").read_text())
transforms = {t["name"] for t in example["transforms"]}


def resolves(key):
    folder, _, lang = key.rpartition("_")
    return (key in allowed
            or all(part in coding_keys for part in key.split("."))
            or key in transforms
            or bool(folder) and (root / "built-in/transforms" / folder / f"{lang}.py").is_file())


column, checked, bad = None, 0, []
for n, line in enumerate(catalogue.read_text().splitlines(), 1):
    if not line.startswith("|"):
        column = None
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if column is None:
        column = cells.index("Key") if "Key" in cells else -1
        continue
    if column < 0 or set(cells[0]) <= {"-"}:
        continue
    for span in re.findall(r"`([^`]+)`", cells[column]):
        checked += 1
        if not resolves(span.rstrip(":")):
            bad.append(f"  ✗ {catalogue.name}:{n}: `{span}` is not a Config.swift coding key,"
                       " a transform in config.example.yaml, or a script under built-in/transforms/")

print("\n".join(bad + [f"  {checked - len(bad)}/{checked} keys in the Key column resolve"]))
if checked < 30:
    print("  ✗ fewer than 30 keys found: has the Key column been renamed?")
sys.exit(1 if bad or checked < 30 else 0)
PY
