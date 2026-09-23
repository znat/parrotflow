#!/usr/bin/env python3
"""What the seen filter makes of a recorded run, offline.

    scripts/see-run.py <run folder> <tree> [<tree> ...] [--app .build/debug/ParrotFlow]

For each tree, reads the text in its screenshot and in the one before with
`ParrotFlow --look-image --json`, and prints what `loop.changes` would report
from it: blocks of text that appeared and are not in the tree, controls still
on screen that left the tree, and, for the step taken from that tree, whether
its target is covered. Prints to the terminal only: the text is private.
"""

import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "built-in", "recipes"))

import loop  # noqa: E402


def read(folder, n, app, cache):
    if n in cache:
        return cache[n]
    path = os.path.join(folder, "trees", f"{n:02d}.json")
    if not os.path.exists(path):
        cache[n] = None
        return None
    with open(path, encoding="utf-8") as handle:
        tree = json.load(handle)
    snapshot, shot = tree["snapshot"], tree.get("shot") or {}
    snapshot["seen"], ms = None, None
    if shot.get("file"):
        out = subprocess.run(
            [app, "--look-image", os.path.join(folder, shot["file"]),
             "--scale", str(shot.get("scale") or 2), "--json"],
            capture_output=True, text=True, check=True).stdout
        found = json.loads(out.strip().splitlines()[-1])
        frame = shot["frame"]
        snapshot["seen"] = [dict(line, x=line["x"] + frame["x"], y=line["y"] + frame["y"])
                            for line in found["lines"]]
        ms = found["ms"]
    cache[n] = (snapshot, ms)
    return cache[n]


def main(arguments):
    app = os.path.join(ROOT, ".build", "debug", "ParrotFlow")
    if "--app" in arguments:
        at = arguments.index("--app")
        app = arguments[at + 1]
        del arguments[at:at + 2]
    if len(arguments) < 2:
        print(__doc__.strip().splitlines()[2])
        return 2
    folder, trees = arguments[0], [int(n) for n in arguments[1:]]
    steps = []
    for name in sorted(os.listdir(os.path.join(folder, "steps"))):
        with open(os.path.join(folder, "steps", name), encoding="utf-8") as handle:
            steps.append(json.load(handle))
    cache = {}
    for n in trees:
        now = read(folder, n, app, cache)
        if now is None:
            print(f"tree {n}: not recorded")
            continue
        after, ms = now
        before = (read(folder, n - 1, app, cache) or (None,))[0]
        print(f"tree {n}: {len(after['items'])} items, {len(after['seen'] or ())} lines seen"
              + (f" in {ms} ms (warm, from the JPEG)" if ms is not None else ""))
        blocks, still = loop.seen_changes(before, after)
        for block in blocks:
            print(f"  block near “{block.get('near', '')}”:")
            for line in block["lines"]:
                print(f"    {line['x']:5.0f},{line['y']:5.0f}  {line['text']}")
        if still:
            print("  still on screen, no longer in the tree:")
            for line in still:
                print(f"    {line['x']:5.0f},{line['y']:5.0f}  {line['role']} “{line['name']}”"
                      f" — seen “{line['text']}”")
        if not blocks and not still:
            print("  nothing seen that the tree lacks")
        change = loop.changes(before, after) if before else {}
        if change:
            print(f"  sentence: {loop.sentence(change)}")
        for step in steps:
            target = step.get("target")
            if step.get("tree_before") != n or not target or target.get("kind") == "seen":
                continue
            over = loop.covering(target, after)
            state = [i for i in after["items"] if "expanded" in (i.get("state") or ())]
            said = f"  step {step['n']} ({step['do']} “{target.get('name')}”): "
            if over:
                said += (f"“{target.get('name')}” is covered by text seen on screen: "
                         + ", ".join(f"“{line['text']}”" for line in over))
                if state:
                    said += f"; “{loop.decider.label(state[0])}” is expanded: Return first"
            else:
                said += "not covered"
            print(said)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
