#!/usr/bin/env bash
#
# config.appstore.yaml is what a new App Store install gets, and the sandbox
# is what makes it a different file from config.example.yaml. This is the
# guard on that difference.
#
# A `command:` here may name one thing only: a script this build ships, under
# `examples/`, run by the Python inside the bundle. Anything else — a program
# on PATH, a shell line, a script of the user's — cannot run, because the
# sandbox executes only what is in the bundle. A `prompt:` cannot run either;
# it needs Ollama installed separately.
#
# The failure either way is quiet: a stage that cannot run leaves the
# transcript alone, which is the right behaviour and looks like the rule not
# matching. Hence a check rather than a bug report six months later.
#
# The second half is what build-app.sh removes from the bundle. `parse` needs
# spaCy and `slack_mentions` is a roster the user edits, so a `command:`
# naming either would resolve in this repository and be absent from the app.
#
# Runs without the binary and without a model, so it belongs in `make test`.
set -euo pipefail

# The repository by default. An argument overrides it, which is what lets the
# guard be tested against a deliberately broken copy rather than trusted.
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

python3 - "$ROOT" <<'PY'
import ast, sys, pathlib, yaml

root = pathlib.Path(sys.argv[1])
store = root / "config.appstore.yaml"
direct = root / "config.example.yaml"

failures = []

doc = yaml.safe_load(store.read_text())
reference = yaml.safe_load(direct.read_text())

transforms = doc.get("transforms") or []
names = {t["name"] for t in transforms}

# What build-app.sh strips out of Contents/Resources/examples.
NOT_SHIPPED = {"parse", "slack_mentions"}

# 1. No model call, and no command that is not one of our own scripts.
for t in transforms:
    if "prompt" in t:
        failures.append(
            f"transform {t['name']!r} has a prompt: — this build calls no model")

    command = t.get("command")
    if command is None:
        continue

    if not command.startswith("examples/") or not command.endswith(".py"):
        failures.append(
            f"transform {t['name']!r} runs {command!r} — this build runs only"
            " the scripts it ships, named as examples/<folder>/<script>.py")
        continue

    relative = command[len("examples/"):]
    folder = relative.split("/", 1)[0]
    if folder in NOT_SHIPPED:
        failures.append(
            f"transform {t['name']!r} runs {command!r}, and build-app.sh removes"
            f" examples/transforms/{folder} from the App Store bundle")
        continue

    script = root / "examples" / "transforms" / relative
    if not script.is_file():
        failures.append(f"transform {t['name']!r} runs {command!r}, which is not a file")
        continue

    # Pure standard library at module level. The bundled interpreter has no
    # packages and cannot install any, so a third-party import that runs on
    # import kills the script.
    #
    # Module level only, and the distinction is the whole point.
    # disfluency.py imports spacy inside spacy_or_none(), under
    # `try: ... except ImportError`, and returns None when it is not there —
    # four of its five rules still run. That is the fail-open rule in
    # AGENTS.md working as intended, not a problem to report. An import at the
    # top of the file has no such guard.
    try:
        tree = ast.parse(script.read_text())
    except SyntaxError as error:
        failures.append(f"{command} does not parse: {error}")
        continue

    siblings = {f.stem for f in script.parent.glob("*.py")}
    top_level = set()
    for node in tree.body:
        if isinstance(node, ast.Import):
            top_level.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            top_level.add(node.module.split(".")[0])

    for name in sorted(top_level - siblings):
        if name not in sys.stdlib_module_names:
            failures.append(
                f"{command} imports {name!r} at module level, and it is not in the"
                " standard library — the bundled interpreter has no packages"
                " and cannot install any")

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

shipped = sum(1 for t in transforms if "command" in t)
print(f"config.appstore.yaml: {len(transforms)} transforms "
      f"({shipped} running a bundled script), {len(pipeline)} pipeline steps,"
      f" no prompt:, no models:, nothing outside the bundle")
PY
