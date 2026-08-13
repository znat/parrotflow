#!/usr/bin/env bash
# Checks that config.example.yaml — what a new install is written with, and
# what anyone reads to find out what exists — is one file, not two drifting
# copies of the same shape.
#
# It used to be two: `Config.defaultYAML`, a hand-synced Swift string written
# on first launch, and config.example.yaml, read by everyone else. They
# drifted, silently, more than once — `languages` went missing from the
# string while the example kept it; then the vocabulary judge stage and the
# app-scoped transforms landed in the example and never reached the string,
# so a new install ran a pipeline with no judge in it and nothing said so. A
# key-name comparison between the two caught the first kind of drift and was
# structurally blind to the second: a missing pipeline *step* is not a
# missing *key*.
#
# `Config.defaultYAML` now reads config.example.yaml itself and substitutes
# four lines that differ per variant — see Config.configTemplateURL. There is
# one file, so there is nothing left to drift. What is left to check:
#
#   1. config.example.yaml still parses as YAML.
#   2. Every pipeline step still names something real — a `stage:` this app
#      knows, or a `transform:` this file defines.
#   3. Config.defaultYAML has not grown back into a second copy — the
#      regression this check exists to catch.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import re, sys, pathlib, yaml

root = pathlib.Path(sys.argv[1])
ok = True

example_path = root / "config.example.yaml"
try:
    example = yaml.safe_load(example_path.read_text())
except yaml.YAMLError as error:
    print(f"  ✗ config.example.yaml is not valid YAML")
    print(f"      {error}")
    sys.exit(1)

# Every transform this file defines, by name.
def names(doc):
    entries = (doc.get("transforms") or []) + (doc.get("prompts") or [])
    return {e.get("name") for e in entries}

defined = names(example)

# The stage kinds this app understands without a name — everything else in a
# pipeline step must be one of these, or a `transform:` naming a defined one.
BUILTIN_STAGES = {"replacements", "fuzzy", "numbers", "vocabulary"}

def steps(doc):
    found = []
    for entries in ((doc.get("transcription") or {}).get("pipelines") or {}).values():
        for entry in entries or []:
            if isinstance(entry, str):
                found.append(("stage", entry))
            elif isinstance(entry, dict):
                if entry.get("transform"):
                    found.append(("transform", entry["transform"]))
                elif entry.get("stage"):
                    found.append(("stage", entry["stage"]))
    return found

for kind, step in steps(example):
    if kind == "transform" and step not in defined:
        print(f"  ✗ pipeline runs `transform: {step}`, which config.example.yaml never defines")
        ok = False
    elif kind == "stage" and step not in BUILTIN_STAGES:
        print(f"  ✗ pipeline runs `stage: {step}`, which is not a stage this app knows"
              f" ({', '.join(sorted(BUILTIN_STAGES))})")
        ok = False

# The regression this whole check exists to catch: defaultYAML growing back
# into a second, hand-synced copy of the config's shape. It should be a few
# lines that read the file and swap in the variant-specific ones — not
# something that itself defines `transforms:`, `pipelines:`, or `llm:`.
config_swift = (root / "Sources/ParrotFlow/Config.swift").read_text()
start = config_swift.index("static var defaultYAML: String {")
end = config_swift.index("\n}", start) if "\n}" in config_swift[start:] else len(config_swift)
body = config_swift[start:start + 2000] if end == len(config_swift) else config_swift[start:end]

if "configTemplateURL" not in body:
    print("  ✗ Config.defaultYAML no longer reads configTemplateURL — has it gone back to"
          " being a literal string? That is the two-copies problem this check exists to catch.")
    ok = False
if re.search(r"\btransforms:\s*$", body, re.MULTILINE) or "pipelines:" in body:
    print("  ✗ Config.defaultYAML appears to embed config content directly (`transforms:` or"
          " `pipelines:` found in its body) — that is the two-copies problem this check exists"
          " to catch")
    ok = False

if ok:
    print(f"  ✓ config.example.yaml is the one copy, parses, and its pipeline"
          f" names only real stages and transforms"
          f"  ({len(defined)} transforms, {len(steps(example))} pipeline step(s))")
sys.exit(0 if ok else 1)
PY
