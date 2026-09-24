"""Skills: memories with steps the runner plays itself.

A memory file whose front matter has a `steps:` list is a skill. Each step is
one gesture and, after `|`, what must be true after it:

    steps:
      - click DateTimeArea "Start time" at left | focus "Start time"
      - type {hour} | value "Start time" ~ "*, {hour}:*"
      - key right
      - type {minute} | value "Start time" ~ "*, {hour}:{minute}"

Gestures: `click <Role> "<name>" [at left|right]`, `type <text>`, `key <keys>`.
Checks, read from the tree by code: `focus "<name>"`, `value "<name>" ~ "<glob>"`,
`window ~ "<glob>"`, `appears "<glob>"`. `{param}` is filled from the call.

The model calls a skill with `use`. No model runs while it plays. The first
check that fails stops it, and the model gets what was expected and what the
tree holds instead.
"""

import fnmatch
import glob
import os
import re
import time

import decider

_STEP = re.compile(r'^\s*-\s*(.+?)\s*(?:\|\s*(.+?))?\s*$')
_CLICK = re.compile(r'^click\s+(\w+)\s+"([^"]+)"(?:\s+at\s+(left|right))?$')
_FOCUS = re.compile(r'^focus\s+"([^"]+)"$')
_VALUE = re.compile(r'^value\s+"([^"]+)"\s*~\s*"([^"]*)"$')
_WINDOW = re.compile(r'^window\s*~\s*"([^"]*)"$')
_APPEARS = re.compile(r'^appears\s+"([^"]*)"$')
# Points in from the edge for `at left`. Measured 09-24 on Outlook's date and
# time fields: 10 lands before the hour's first digit, 18 on both parts.
EDGE = 16
# Reads after a gesture before a check fails: the app redraws late.
TRIES = 3
PAUSE = 0.3


class Skill:
    def __init__(self, name, goal, params, steps):
        self.name, self.goal, self.params, self.steps = name, goal, params, steps
        # The controls its clicks name, as (role, name): the skill sets them.
        self.covers = {m.groups()[:2] for m in (_CLICK.match(g) for g, _ in steps) if m}

    def line(self):
        covers = ", ".join(f'"{name}"' for _, name in sorted(self.covers))
        return f"{self.name}({', '.join(self.params)}): {self.goal}" \
            + (f" Sets {covers}; never set it with `act`." if covers else "")


def parse(path):
    """The skill in a memory file, or None when it has no steps."""
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except (OSError, UnicodeDecodeError):
        return None
    return parse_text(text, os.path.splitext(os.path.basename(path))[0])


def parse_text(text, name):
    head = text.split("---")
    if len(head) < 3:
        return None
    goal, params, steps, in_steps = "", [], [], False
    for line in head[1].splitlines():
        if in_steps and line.startswith((" ", "\t")):
            found = _STEP.match(line)
            if found:
                steps.append((found.group(1), found.group(2) or ""))
            continue
        in_steps = False
        key, _, rest = line.partition(":")
        rest = rest.strip()
        if key == "goal":
            goal = rest
        elif key == "params":
            params = [p.strip() for p in rest.strip("[]").split(",") if p.strip()]
        elif key == "steps":
            in_steps = True
    if not steps:
        return None
    return Skill(name, goal, params, steps)


def problems(text):
    """Why the `steps:` block of a memory would not play, one line each.
    `parse_text` skips a line it cannot read; this names it."""
    head = text.split("---")
    if len(head) < 3:
        return ["no front matter"]
    skill = parse_text(text, "memory")
    params = skill.params if skill else []
    out, in_steps, found = [], False, False
    for line in head[1].splitlines():
        if in_steps and line.startswith((" ", "\t")):
            step = _STEP.match(line)
            if not step:
                out.append(f"cannot read the step {line.strip()!r}")
                continue
            gesture, expect = step.group(1), step.group(2) or ""
            if not (_CLICK.match(gesture) or re.match(r"^(type|key)\s+\S", gesture)):
                out.append(f"cannot do {gesture!r}")
            if expect and not any(p.match(expect) for p in (_FOCUS, _VALUE, _WINDOW, _APPEARS)):
                out.append(f"cannot check {expect!r}")
            unknown = [n for n in re.findall(r"\{(\w+)\}", gesture + expect) if n not in params]
            if unknown:
                out.append(f"{{{unknown[0]}}} is not in params")
            continue
        in_steps = line.partition(":")[0] == "steps"
        found = found or in_steps
    if found and skill is None and not out:
        out.append("no step could be read")
    return out


def of_app(root, folder):
    """The skills in `<root>/<folder>/`, by name."""
    found = (parse(p) for p in sorted(glob.glob(os.path.join(root, folder or "-", "*.md"))))
    return {s.name: s for s in found if s}


def covering(found, item):
    """The skill in `found` that sets `item`, or None."""
    key = (item["role"].replace("AX", ""), item["name"])
    return next((s for s in found.values() if key in s.covers), None)


def _fill(text, values):
    return re.sub(r"\{(\w+)\}", lambda m: values.get(m.group(1), m.group(0)), text)


def _named(snapshot, name, role=None):
    """Items called `name`, of `role` when given, best first."""
    items = [i for i in snapshot["items"] if i["name"] == name
             and (role is None or i["role"].replace("AX", "") == role)]
    return sorted(items, key=decider.twin_rank)


def check(expect, snapshot):
    """(whether `expect` holds in `snapshot`, what the tree holds instead)."""
    if not expect:
        return True, ""
    found = _FOCUS.match(expect)
    if found:
        focused = [i["name"] for i in snapshot["items"] if "focused" in (i.get("state") or ())]
        return found.group(1) in focused, f"focus is in {focused[0]!r}" if focused else "no focus"
    found = _VALUE.match(expect)
    if found:
        items = _named(snapshot, found.group(1))
        items = [i for i in items if i.get("value")] or items
        value = items[0].get("value", "") if items else None
        if value is None:
            return False, f"no {found.group(1)!r} on screen"
        return fnmatch.fnmatchcase(value, found.group(2)), f"{found.group(1)!r} = {value!r}"
    found = _WINDOW.match(expect)
    if found:
        return fnmatch.fnmatchcase(snapshot["window"], found.group(1)), \
            f"the window is {snapshot['window']!r}"
    found = _APPEARS.match(expect)
    if found:
        return any(fnmatch.fnmatchcase(i["name"], found.group(1)) for i in snapshot["items"]), \
            f"nothing called {found.group(1)!r}"
    return False, f"cannot check {expect!r}"


def play(skill, values, agent):
    """Plays `skill` with `values` through the agent's loop. (whether every
    check passed, one line per step)."""
    lp, report = agent.loop, agent.report
    filled = dict(zip(skill.params, values))
    said = []
    for n, (gesture, expect) in enumerate(skill.steps, 1):
        gesture, expect = _fill(gesture, filled), _fill(expect, filled)
        why = _gesture(gesture, agent)
        if why:
            said.append(f"{n}. {gesture} — failed: {why}")
            return False, said
        report.acted = True
        report.shown.append(gesture)
        for attempt in range(TRIES):
            time.sleep(PAUSE)
            agent.snapshot = lp._read(agent.aim, agent.snapshot["app"])
            ok, found = check(expect, agent.snapshot)
            if ok:
                break
        lp.log(f"skill: {skill.name} {n}. {gesture}" + (f" | {expect} — "
               + ("ok" if ok else f"no: {found}") if expect else ""))
        if not ok:
            said.append(f"{n}. {gesture} — expected {expect}, but {found}")
            return False, said
        said.append(f"{n}. {gesture}" + (f" — {found}" if expect and found else ""))
    return True, said


def _gesture(gesture, agent):
    """Does one gesture. Why it could not, or None."""
    lp = agent.loop
    if gesture.startswith("click "):
        found = _CLICK.match(gesture)
        if not found:
            return f"cannot read {gesture!r}"
        role, name, side = found.groups()
        items = _named(agent.snapshot, name, role)
        if not items:
            return f"no {role} {name!r} on screen"
        item = items[0]
        x = item["x"]
        if side == "left":
            x = item["x"] - item["w"] / 2 + EDGE
        elif side == "right":
            x = item["x"] + item["w"] / 2 - EDGE
        return lp._click_at({"x": x, "y": item["y"], "name": name})
    if gesture.startswith("type "):
        lp.front()
        reply = lp.call("type", text=gesture[5:])
        return reply.get("error")
    if gesture.startswith("key "):
        lp.front()
        reply = lp.call("key", keys=gesture[4:].strip())
        return reply.get("text") or reply.get("error")
    return f"cannot read {gesture!r}"
