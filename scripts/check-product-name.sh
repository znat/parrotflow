#!/usr/bin/env bash
#
# The product name is one string, and this is what keeps it one.
#
# Two things go wrong on their own. AppVariant.productName and PRODUCT_NAME in
# scripts/variant.sh can drift, and then the bundle says one name and the app
# says another. And a new user-facing string can hardcode the name again,
# which nothing notices until a rename ships half-applied.
#
# What is deliberately NOT threaded, and why each one is allowed below:
#
#   usage: lines   name the binary. SwiftPM produces `ParrotFlow` and
#                  CFBundleExecutable must match it, so renaming the app does
#                  not rename what you type.
#   [ParrotFlow]   what `log show` is filtered on. A grep token.
#   User-Agent     sent to GitHub. A protocol identifier.
#   # ParrotFlow configuration
#                  the anchor Config.defaultYAML substitutes against. It has
#                  to match config.example.yaml byte for byte.
#   .app .zip .log, open -a, /Applications/
#                  bundle names, the release archive, and files on disk. These
#                  follow APP_NAME and identity, not the display name.
#   a bare "ParrotFlow"
#                  a path component or a test fixture, never prose.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

python3 - "$ROOT" <<'PY'
import re, sys, pathlib

root = pathlib.Path(sys.argv[1])
ok = True

swift = (root / "Sources/ParrotFlow/AppVariant.swift").read_text()
shell = (root / "scripts/variant.sh").read_text()

m = re.search(r'static let productName = "([^"]+)"', swift)
n = re.search(r'^PRODUCT_NAME="([^"]+)"', shell, re.MULTILINE)
if not m or not n:
    print("  ✗ no productName in AppVariant.swift, or no PRODUCT_NAME in variant.sh")
    sys.exit(1)

name = m.group(1)
if name != n.group(1):
    print(f"  ✗ AppVariant.productName is {name!r}"
          f" and variant.sh PRODUCT_NAME is {n.group(1)!r}")
    ok = False

# Both spellings. The current name catches a string written today; the on-disk
# identity name catches what a rename leaves behind, all of which is allowed
# below — checking it is what proves the rename moved nothing it should not.
identity = re.search(r'identityName: String \{ isDev \? "([^"]+) Dev"', swift)
NAMES = sorted({name} | ({identity.group(1)} if identity else set()),
               key=len, reverse=True)


def allowed(inner: str) -> bool:
    # `usage: ParrotFlow --x`, and the indented continuations under it. Both
    # name the binary, which a rename does not touch.
    if "usage:" in inner:
        return True
    if inner.lstrip().startswith("open -a "):
        return True
    if "/Applications/" in inner:
        return True

    for n in NAMES:
        # A bare token is never prose: a path component, a bundle name, or a
        # fixture — ParsingInstall's Application Support directory,
        # SoundCommand's pronunciation case, AppVariant defining the name.
        if inner in (n, f"{n} Dev") or inner.startswith(f"{n}Dev"):
            return True
        if inner.startswith("   ") and f"{n} --" in inner:
            return True
        for fragment in (
            f"[{n}]",                      # the unified-log tag
            f"# {n} configuration",        # the defaultYAML anchor
            f"{n}.app", f"{n}.zip",        # bundle name, release archive
            f"{n}.log", f"{n}-Dev.log",    # log files, which are identity
            f"{n}/",                       # the User-Agent, and paths
            "com.parrotflow",              # bundle identifiers
            f"parrot flow -> {n}",         # a sound-mapping example
            f"run {n} with no arguments",  # the binary again
        ):
            if fragment in inner:
                return True
    return False


# Whole words. A rename to a prefix of the old name turns a substring scan
# into nonsense: with "Parrot", MenuBarParrotTemplate, ParrotSolid and every
# remaining ParrotFlow match, and none is the product name written out.
pattern = re.compile(
    r'"[^"\n]*(?<![A-Za-z0-9])(?:'
    + "|".join(re.escape(x) for x in NAMES)
    + r')(?![A-Za-z0-9])[^"\n]*"'
)

offenders = []
for f in sorted((root / "Sources").rglob("*.swift")):
    for number, line in enumerate(f.read_text().splitlines(), 1):
        if line.lstrip().startswith("//"):
            continue
        for match in pattern.finditer(line):
            if not allowed(match.group(0)[1:-1]):
                offenders.append((f.name, number, match.group(0)[:76]))

if offenders:
    ok = False
    print(f"  ✗ {len(offenders)} string(s) hardcode the product name where"
          " AppVariant.displayName belongs:")
    for file, number, literal in offenders:
        print(f"      {file}:{number}  {literal}")
    print("     Thread them, or add the reason to allowed() in this script.")

if ok:
    print(f"  ✓ the product name is {name!r} in one place,"
          " and no user-facing string repeats it")
sys.exit(0 if ok else 1)
PY
