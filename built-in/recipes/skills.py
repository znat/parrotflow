"""Skills: memories with steps the runner plays itself.

A memory file whose front matter has a `steps:` list is a skill. Each step is
one gesture and, after `|`, what must be true after it:

    steps:
      - click DateTimeArea "Start time" at left | focus "Start time"
      - type {hour} | value "Start time" ~ "*, {hour}:*"
      - key right
      - type {minute} | value "Start time" ~ "*, {hour}:{minute}"

Gestures: `click <Role> "<name>" [at left|right]`, `type <text>`, `key <keys>`,
`caret "<field>" at start|end|before "<text>"|after "<text>"`, `select "<field>" "<text>"`,
`click picture "<text>" [below|above|right of|left of "<anchor>"]`.
Checks, read from the tree by code: `focus "<name>"`, `value "<name>" ~ "<glob>"`,
`window ~ "<glob>"`, `appears "<glob>"`. `{param}` is filled from the call.

`click picture` is for a target the tree may not have, such as Teams'
attendee suggestions. The first that finds `<text>` is clicked: an item of
the tree called `<text>`, then a line of the read's text seen in the pixels
that is or starts with `<text>`, then `ground` on the picture. With an
anchor, each looks only on that side of it, and the nearest one wins. The
step says which found it and where.

The model calls a skill with `use`. No model runs while it plays. The first
check that fails stops it, and the model gets what was expected and what the
tree holds instead.
"""

import fnmatch
import glob
import os
import re

import decider
import ground as grounding
import loop as looping
import planner as planning

_STEP = re.compile(r'^\s*-\s*(.+?)\s*(?:\|\s*(.+?))?\s*$')
_CLICK = re.compile(r'^click\s+(\w+)\s+"([^"]+)"(?:\s+at\s+(left|right))?$')
_CARET = re.compile(r'^caret\s+"([^"]+)"\s+at\s+(?:(start|end)|(before|after)\s+"([^"]+)")$')
_PICTURE = re.compile(r'^click\s+picture\s+"([^"]+)"'
                      r'(?:\s+(below|above|right of|left of)\s+"([^"]+)")?$')
_SELECT = re.compile(r'^select\s+"([^"]+)"\s+"([^"]+)"$')
_FOCUS = re.compile(r'^focus\s+"([^"]+)"$')
_VALUE = re.compile(r'^value\s+"([^"]+)"\s*~\s*"([^"]*)"$')
_WINDOW = re.compile(r'^window\s*~\s*"([^"]*)"$')
_APPEARS = re.compile(r'^appears\s+"([^"]*)"$')
# Points in from the edge for `at left`. Measured 09-24 on Outlook's date and
# time fields: 10 lands before the hour's first digit, 18 on both parts.
EDGE = 16
# Points: the part of the screen `click picture` looks at, beside its anchor.
REACH = grounding.CROP_H
ACROSS = 400
MARGIN = 40
KEEP = {"below": "top", "above": "bottom", "right of": "left", "left of": "right"}


class Skill:
    def __init__(self, name, goal, params, steps):
        self.name, self.goal, self.params, self.steps = name, goal, params, steps
        # The controls its clicks name, as (role, name): the skill sets them.
        self.covers = {m.groups()[:2] for m in (_CLICK.match(g) for g, _ in steps
                                                  if not _PICTURE.match(g)) if m}

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
            if not (_CLICK.match(gesture) or _PICTURE.match(gesture) or _CARET.match(gesture)
                    or _SELECT.match(gesture)
                    or re.match(r"^(type|key)\s+\S", gesture)):
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
        how = ""
        if _PICTURE.match(gesture):
            why, how = _picture(gesture, agent)
        else:
            why = _gesture(gesture, agent)
        if why:
            said.append(f"{n}. {gesture} — failed: {why}")
            return False, said
        report.acted = True
        report.shown.append(gesture)
        if expect:
            agent.snapshot = lp.settle(agent.snapshot, agent.aim, "skill_check",
                                       until=lambda now: check(expect, now)[0])
        else:
            agent.snapshot = lp.settle(agent.snapshot, agent.aim, "skill_step")
        ok, found = check(expect, agent.snapshot)
        gesture += f" ({how})" if how else ""
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
    if gesture.startswith(("caret ", "select ")):
        return _edit(gesture, agent)
    if gesture.startswith("key "):
        lp.front()
        reply = lp.call("key", keys=planning.chord(gesture[4:]))
        return reply.get("text") or reply.get("error")
    return f"cannot read {gesture!r}"


def _edit(gesture, agent):
    """`caret` or `select`: the field clicked unless the caret is in it,
    then the loop's own move, which reads the selection back."""
    lp = agent.loop
    caret = _CARET.match(gesture)
    select = _SELECT.match(gesture)
    if not caret and not select:
        return f"cannot read {gesture!r}"
    name = (caret or select).group(1)
    fields = [i for i in _named(agent.snapshot, name) if i["kind"] == "text"]
    if not fields:
        return f"no text field {name!r} on screen"
    field = fields[0]
    if not lp._caret_in(field, agent.snapshot) and lp.placed != looping.identity(field):
        why = lp._press(field, click=False)
        if why:
            return why
        agent.snapshot = lp.settle(agent.snapshot, agent.aim, "before_type")
    lp.front()
    if caret:
        why, _ = lp._edit("caret", field, caret.group(2) or caret.group(3), caret.group(4) or "")
    else:
        why, _ = lp._edit("select", field, None, select.group(2))
    return why


def _picture(gesture, agent):
    """`click picture`: (why it could not, or None; which way found the
    target and where)."""
    lp, snapshot = agent.loop, agent.snapshot
    text, side, name = _PICTURE.match(gesture).groups()
    anchor, box, where = None, None, ""
    if name:
        anchors = _named(snapshot, name)
        if not anchors:
            return f"no {name!r} on screen, the anchor for {text!r}", ""
        anchor, where = anchors[0], f" {side} {name!r}"
        box = _beside(anchor, side)

    def best(found):
        inside = [f for f in found if box is None or _within(f, box)]
        if not inside or anchor is None:
            return inside[0] if inside else None
        return min(inside, key=lambda f: (f["x"] - anchor["x"]) ** 2 + (f["y"] - anchor["y"]) ** 2)

    item = best(_named(snapshot, text))
    if item is not None:
        return lp._click_at({"x": item["x"], "y": item["y"], "name": text}), \
            f"tree at {item['x']:.0f},{item['y']:.0f}"
    want = _plain(text)
    line = best([line for line in snapshot.get("seen") or () if isinstance(line, dict)
                 and _starts(_plain(line.get("text", "")), want)])
    if line is not None:
        return lp._click_at({"x": line["x"], "y": line["y"], "name": text}), \
            f"seen \"{_plain(line['text'])}\" at {line['x']:.0f},{line['y']:.0f}"
    shot = snapshot.get("shot") or {}
    tried, error = "the tree or the text", ""
    if box is not None and agent.grounder.on and shot.get("file"):
        region = {"x": (box[0] + box[2]) / 2, "y": (box[1] + box[3]) / 2,
                  "w": box[2] - box[0], "h": box[3] - box[1]}
        crop = grounding.crop_box(region, shot["frame"], KEEP[side])
        if crop is not None:
            tried = "the tree, the text or the picture"
            found = agent.grounder.point(shot, crop, text, agent.planner, lp.log)
            agent._record_ground(found, text, crop, shot, why="skill")
            error = found.get("error") or ""
            if found.get("point") is not None:
                x, y = found["point"]
                return lp._click_at({"x": x, "y": y, "name": text}), \
                    f"picture ({found['method']}) at {x:.0f},{y:.0f}"
    return f"no {text!r}{where} in {tried}" + (f"; the picture: {error}" if error else ""), ""


def _beside(item, side):
    """(left, top, right, bottom) of the part of the screen on `side` of `item`."""
    left, top = item["x"] - item.get("w", 0) / 2, item["y"] - item.get("h", 0) / 2
    right, bottom = left + item.get("w", 0), top + item.get("h", 0)
    wide = max(right + MARGIN, left - MARGIN + ACROSS)
    return {"below": (left - MARGIN, bottom, wide, bottom + REACH),
            "above": (left - MARGIN, top - REACH, wide, top),
            "right of": (right, item["y"] - ACROSS / 2, right + REACH, item["y"] + ACROSS / 2),
            "left of": (left - REACH, item["y"] - ACROSS / 2, left, item["y"] + ACROSS / 2)}[side]


def _within(thing, box):
    return box[0] <= thing["x"] <= box[2] and box[1] <= thing["y"] <= box[3]


def _plain(text):
    return " ".join(str(text).lower().split())


def _starts(line, want):
    """Whether `line` is `want`, or starts with it as whole words."""
    return line == want or line.startswith(want) and not line[len(want)].isalnum()
