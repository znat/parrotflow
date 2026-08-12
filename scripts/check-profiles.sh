#!/usr/bin/env bash
# Checks that `AppProfile.of` classifies each app in tests/profile-cases.yaml
# the way the case file says it should.
#
# This is the routing every dictation turns on, and it is the one part of the
# destination path that can be checked without a screen, a microphone or a real
# app in front: given a bundle id and a name, which focus rule, which pill
# anchor, and whether the pane is readable.
#
# It cannot check the things underneath it — that Codex really does refuse
# `AXManualAccessibility`, that VS Code really does take it, that a ⌘V really
# lands. Those need the apps and stay manual, like check-inplace.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Release first, as the other check scripts do and as CI builds. Debug is the
# fallback so this also runs after a plain `swift build`.
BIN="$ROOT/.build/release/ParrotFlow"
[ -x "$BIN" ] || BIN="$ROOT/.build/debug/ParrotFlow"
[ -x "$BIN" ] || { echo "build first: swift build -c release"; exit 1; }

python3 - "$ROOT" "$BIN" <<'PY'
import subprocess, sys, pathlib, yaml

root, binary = pathlib.Path(sys.argv[1]), sys.argv[2]
cases = yaml.safe_load((root / "tests/profile-cases.yaml").read_text())

ok = True
for case in cases:
    result = subprocess.run(
        [binary, "--profile", case["bundle"], case.get("name", "")],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"  ✗ {case['what']}: exited {result.returncode}")
        print(f"      {result.stderr.strip() or result.stdout.strip()}")
        ok = False
        continue

    # `--profile` prints one "key  value" per line.
    got = {}
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2:
            got[parts[0]] = parts[1]

    for field in ("focus", "anchor", "readsPane"):
        want = str(case[field]).lower()
        if got.get(field, "").lower() != want:
            print(f"  ✗ {case['what']}")
            print(f"      {case['bundle']} / \"{case.get('name', '')}\"")
            print(f"      {field}: wanted {want}, got {got.get(field, 'nothing')}")
            ok = False

if ok:
    print(f"  ✓ every app is classified as the case file says  ({len(cases)} cases)")
sys.exit(0 if ok else 1)
PY
