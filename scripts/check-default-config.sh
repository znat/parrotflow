#!/usr/bin/env bash
# Checks that what a new install is written with teaches everything
# config.example.yaml documents.
#
# There are two copies of the config's shape — `Config.defaultYAML`, which is
# written on first launch, and config.example.yaml, which is what anyone reads
# to find out what exists. They drift, and the drift is silent both ways: a key
# missing from the template is a feature nobody discovers, and a key missing
# from the example is one nobody can look up.
#
# It has already bitten twice. `languages` was absent from the template, so a
# new install shipped a pipeline whose comment promised numbers in French while
# listing only English. Then `prompts` was absent, so "hey parrot, make that a
# list" did nothing on a fresh machine and nothing said why.
#
# Only the template is required to be complete. The example deliberately starts
# at `transcription:` and says nothing about hotkeys or audio, so keys the
# template has and the example lacks are reported and not failed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import re, sys, pathlib, yaml

root = pathlib.Path(sys.argv[1])
src = (root / "Sources/ParrotFlow/Config.swift").read_text()
start = src.index('static var defaultYAML: String {')
open_quote = src.index('"""', start) + 3
close_quote = src.index('"""', open_quote)
# The template is a Swift literal: interpolations stand in for per-variant
# values, and an escaped backslash is one backslash by the time YAML sees it.
raw = re.sub(r'\\\((.*?)\)', 'placeholder', src[open_quote:close_quote]).replace("\\\\", "\\")

try:
    template = yaml.safe_load(raw)
except yaml.YAMLError as error:
    print("  ✗ Config.defaultYAML is not valid YAML — a new install would fail to parse")
    print(f"      {error}")
    sys.exit(1)

example = yaml.safe_load((root / "config.example.yaml").read_text())

def keys(node, prefix=""):
    found = []
    for key, value in (node or {}).items():
        found.append(prefix + key)
        # `replacements` and `pipelines` hold user data, not schema; their keys
        # are names and languages, and comparing those would be nonsense.
        if isinstance(value, dict) and key not in ("replacements", "pipelines"):
            found += keys(value, prefix + key + ".")
    return found

missing = sorted(set(keys(example)) - set(keys(template)))
extra = sorted(set(keys(template)) - set(keys(example)))

ok = True
for key in missing:
    print(f"  ✗ {key} is in config.example.yaml but not in the file a new install gets")
    ok = False
# The example starts at `transcription:` by design, so the hotkey, audio and
# feedback sections are permanently "extra". Counted rather than listed: twelve
# lines of expected noise on every run is how a check stops being read.
if extra:
    print(f"  · {len(extra)} keys are written on install and not documented in the example"
          f" ({', '.join(sorted({k.split('.')[0] for k in extra}))})")

# Prompts are a list, so the key check above says nothing about which ones.
def names(doc):
    return {p.get("name") for p in (doc.get("prompts") or [])}
for name in sorted(names(example) - names(template)):
    print(f"  ✗ prompt \"{name}\" is documented but not written on install")
    ok = False

if ok:
    print(f"  ✓ a new install gets every key config.example.yaml documents"
          f"  ({len(keys(template))} keys, {len(names(template))} prompts)")
sys.exit(0 if ok else 1)
PY
