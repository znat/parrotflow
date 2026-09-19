#!/usr/bin/env bash
#
# config.appstore.yaml is what a new App Store install gets, and the sandbox
# is what makes it a different file from config.example.yaml. This is the
# guard on that difference.
#
# A `command:` or a `prompt:` that reached this file would ship a default
# config whose stages cannot run: the sandbox refuses to spawn a program, and
# a prompt needs Ollama installed separately. The failure is quiet — a stage
# that cannot run leaves the transcript alone, which is the right behaviour
# and looks like the rule not matching.
#
# Runs without the binary and without a model, so it belongs in `make test`.
set -euo pipefail

# The repository by default. An argument overrides it, which is what lets the
# guard be tested against a deliberately broken copy rather than trusted.
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

python3 - "$ROOT" <<'PY'
import sys, pathlib, yaml

root = pathlib.Path(sys.argv[1])
store = root / "config.appstore.yaml"
direct = root / "config.example.yaml"

failures = []

doc = yaml.safe_load(store.read_text())
reference = yaml.safe_load(direct.read_text())

transforms = doc.get("transforms") or []
names = {t["name"] for t in transforms}

# 1. Nothing that spawns a process or calls a model.
for t in transforms:
    for banned in ("command", "prompt"):
        if banned in t:
            failures.append(
                f"transform {t['name']!r} has a {banned}: — the sandbox cannot run it")

# 2. No models: block. Every prompt stage is gone, so a model name here would
#    only be a config error waiting for someone to point a transform at it.
if "models" in doc:
    failures.append("models: is present — the App Store build calls no model")

# 3. Every transform the pipeline names has to exist here. The direct build's
#    config is not a fallback: this file is written on its own.
pipeline = (doc.get("transcription") or {}).get("pipeline") or []
for step in pipeline:
    name = step.get("transform")
    if name and name not in names:
        failures.append(f"pipeline names {name!r}, which this file does not define")

# 4. No key this build invented. Drift is the real risk in a second config:
#    a key that exists only here is one nothing else parses or documents.
def keys(node, path=""):
    if isinstance(node, dict):
        for k, v in node.items():
            yield f"{path}.{k}" if path else k
            yield from keys(v, f"{path}.{k}" if path else k)

known = set(keys(reference))
for key in keys(doc):
    # Transform entries are list items, so their keys never appear in either
    # walk; only the mapping spine is compared.
    if key not in known:
        failures.append(f"{key} is not a key config.example.yaml has")

if failures:
    print("config.appstore.yaml:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)

print(f"config.appstore.yaml: {len(transforms)} transforms, "
      f"{len(pipeline)} pipeline steps, no command:, no prompt:, no models:")
PY
