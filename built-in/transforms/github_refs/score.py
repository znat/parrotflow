#!/usr/bin/env python3
"""Score `github_refs` against cases.yaml, from the tree.

    ./score.py
    ./score.py --verbose      # and show the passing cases

Runs the script as the app does: a process per case, the repository URL as
its argument. `ParrotFlow --eval github_refs` scores the copy the app resolves
from the config. No model call in this file.
"""
import argparse
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml")

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "github_refs.py"
REPO = "https://github.com/OWNER/REPO"


def run(text):
    done = subprocess.run([sys.executable, str(SCRIPT), REPO], input=text,
                          capture_output=True, text=True, check=True)
    return done.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verbose", action="store_true", help="show passing cases")
    args = parser.parse_args()

    cases = yaml.safe_load((HERE / "cases.yaml").read_text())["cases"]
    changes = keeps = changed = kept = 0
    for case in cases:
        keep = "expect" not in case
        want = case["input"] if keep else case["expect"]
        got = run(case["input"])
        if keep:
            keeps += 1
        else:
            changes += 1
        if got == want:
            kept += keep
            changed += not keep
            if args.verbose:
                print(f"  ✓ {case['input']}")
            continue
        print(f"  ✗ {case['input']}\n      got   {got}\n      want  {want}")

    print(f"  github_refs   {changed + kept}/{len(cases)}   change {changed}/{changes}"
          f"   keep {kept}/{keeps}")
    sys.exit(0 if changed + kept == len(cases) else 1)


if __name__ == "__main__":
    main()
