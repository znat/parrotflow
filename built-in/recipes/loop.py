"""The loop: one request, as many steps as it takes, when no recipe fits.

`Loop.run` hands the run to the agent (`agent.py`). This file holds what the
agent's steps go through: `_planned_step` and its guards, the reads, and
`changes`, what a step changed. `decide_only` is the decider bench behind
`--act` and `scripts/check-actions.sh`.
"""

import difflib
import re
import time
import unicodedata

import decider
import planner as planning
import runlog as recording

ESCAPED = "Stopped — you pressed escape"
NO_PLANNER = "No planner is set: add actions.planner to the config"
# A target Jev picks below this is not acted on. The narrow pick scored
# 0.95-0.99 when it was right.
PICK_FLOOR = 0.8
UNCHANGED = ("nothing in the accessibility tree changed — not verified: it may still have "
             "worked (a part of a field selected, a field already focused); check the picture")
YES = "Yes, go ahead"
_PLAIN_YES = {"yes", "yeah", "yep", "yup", "sure", "ok", "okay", "go ahead", "yes go ahead",
              "do it", "oui"}
_PLAIN_NO = {"no", "nope", "nah", "no thanks", "dont", "do not", "cancel", "stop", "non"}
# One-line fields, where ⌘A selects only what the field holds.
ONE_LINE = {"AXTextField", "AXComboBox", "AXSearchField"}
OPENS_A_LIST = {"AXComboBox", "AXPopUpButton"}
COVER_HEIGHT = 60
MOVED = 20  # points an item may shift and still be where it was
# After a gesture the window is read every SETTLE_EVERY seconds until it
# changes, for at most the policy's seconds. Each cap is the fixed wait it
# replaced, so a step that changes nothing waits no less than before.
SETTLE_EVERY = 0.15
SETTLE = {"before_type": 0.3, "after_press": 0.5, "after_key": 0.5, "after_type": 1.7,
          "lookup": 1.5, "skill_step": 0.3, "skill_check": 0.9}
# Points below a lookup field where its list may open, and to either side.
LIST_BELOW = 400
LIST_SIDE = 200


def verdict(answer):
    """A guard's answer: YES, None for no, or the user's other words, which
    steer the run. Swift's `Confirm.verdict` is the same rule."""
    if not answer:
        return None
    plain = " ".join("".join(c for c in answer.lower() if c.isalnum() or c.isspace()).split())
    if answer == YES or plain in _PLAIN_YES:
        return YES
    if plain in _PLAIN_NO:
        return None
    return answer.strip()


REDIRECTED = "Not done — the user said: "


def redirected(words):
    """A step the user answered with other words: not done, and why."""
    return f"{REDIRECTED}\"{words}\""


class Stop(Exception):
    """The app refused or ended a step and has said so."""

    def __init__(self, text, broke=False):
        super().__init__(text)
        self.text = text
        self.broke = broke


class Report:
    def __init__(self):
        self.steps = []   # past tense, for `done`
        self.shown = []   # as a person reads them
        self.stopped = ""
        self.acted = False
        # A run that died reading the window after ⌘N reported "Opened a new
        # message" and looked like a success.
        self.broke = False

    @property
    def said(self):
        if not self.shown:
            return self.stopped
        last = self.shown[-1]
        if self.broke:
            return f"{last}, then {self.stopped}"
        return last if len(self.shown) == 1 else f"{last} ({len(self.shown)} steps)"

    @property
    def markdown(self):
        if len(self.shown) <= 1:
            return None
        lines = [f"{i + 1}. {step}" for i, step in enumerate(self.shown)]
        return "\n".join([self.stopped or "Done"] + lines)

    def ending(self):
        if self.broke:
            return "failed"
        if self.stopped == "(planned only)":
            return "planned"
        if self.stopped.endswith("is ready — dictate") or self.stopped == "Waiting for the words":
            return "ready"
        if self.stopped in ("Done", "Nothing to do", "Nothing to do on screen"):
            return "done"
        return "stopped"

    def as_dict(self):
        return {"said": self.said, "markdown": self.markdown, "acted": self.acted,
                "stopped": self.stopped, "steps": self.steps, "shown": self.shown}


def frame(*items):
    """The box around items, as {x, y, w, h} with x, y its centre, the way
    items carry it. None when no item has a size."""
    boxes = [i for i in items if i and i.get("w") and i.get("h")]
    if not boxes:
        return None
    left = min(i["x"] - i["w"] / 2 for i in boxes)
    top = min(i["y"] - i["h"] / 2 for i in boxes)
    right = max(i["x"] + i["w"] / 2 for i in boxes)
    bottom = max(i["y"] + i["h"] / 2 for i in boxes)
    return {"x": (left + right) / 2, "y": (top + bottom) / 2, "w": right - left, "h": bottom - top}


def appeared(before, after):
    """Items now on screen that were not, matched on kind and name."""
    was = {(i["kind"], i["name"]) for i in before["items"]}
    return [i for i in after["items"]
            if (i["kind"], i["name"]) not in was and i["kind"] != "more"]


def _fields(snapshot):
    """What each text field is called, by `id`. Fields with the same name
    are told apart top to bottom, not by distance: the aim moves between
    reads."""
    by_name = {}
    for item in snapshot["items"]:
        if item["kind"] == "text":
            by_name.setdefault(item["name"] or item["role"].replace("AX", ""), []).append(item)
    fields = {}
    for called, items in by_name.items():
        items.sort(key=lambda i: (i["y"], i["x"]))
        for n, item in enumerate(items):
            fields[id(item)] = called if len(items) == 1 else f"{called} {n + 1}"
    return fields


def identity(item):
    """What stays the same for one control across reads: the walk's key
    without its twin number. A tree read before keys: kind and name. Not
    the role: those walks kept a Slack row as an AXRow in one read and an
    AXGroup in the next. Not `in`: Outlook's event form is the window in one
    read and a part that opened in the next."""
    key = item.get("key")
    if key:
        return key.split(".")[0]
    return f"{item['kind']}\x01{item['name']}"


def _distance(a, b):
    return (a["x"] - b["x"]) ** 2 + (a["y"] - b["y"]) ** 2


def _matched(before, after, by=identity):
    """(pairs, gone, added) between two reads' items. Items match on
    `identity`; twins pair nearest first, and the extra ones on either side
    are gone or added. Seen 09-24 in Notion: a hidden copy of the New menu
    stayed in the tree, and opening it doubled four names. What is left
    matches on kind and name, for a key that changed with its path."""
    groups = {}
    for item in before:
        groups.setdefault(by(item), ([], []))[0].append(item)
    for item in after:
        groups.setdefault(by(item), ([], []))[1].append(item)
    pairs, gone, added = [], [], []
    for was, now in groups.values():
        if len(was) == 1 and len(now) == 1:
            pairs.append((was[0], now[0]))
            continue
        options = sorted(((_distance(a, b), i, j) for i, a in enumerate(was)
                          for j, b in enumerate(now)), key=lambda o: o[0])
        left, right = set(range(len(was))), set(range(len(now)))
        for _, i, j in options:
            if i in left and j in right:
                pairs.append((was[i], now[j]))
                left.discard(i)
                right.discard(j)
        gone += [was[i] for i in sorted(left)]
        added += [now[j] for j in sorted(right)]
    if by is identity and gone and added:
        more, gone, added = _matched(gone, added, lambda i: f"{i['kind']}\x01{i['name']}")
        pairs += more
    return pairs, gone, added


def refind(item, snapshot):
    """The same control in `snapshot`: its key, or else kind, role and name
    nearest to where it was."""
    items = snapshot["items"]
    if item.get("key"):
        same = next((i for i in items if i.get("key") == item["key"]), None)
        if same is not None:
            return same
    same = [i for i in items if (i["kind"], i["role"], i["name"])
            == (item["kind"], item["role"], item["name"])]
    return min(same, key=lambda i: _distance(i, item)) if same else None


def _states(item):
    return {s for s in item.get("state") or () if s != "focused"}


def changes(before, after):
    """What the last step did, as data. `window`: its new title. `appeared`:
    per part of the app that opened, its kind, the field it is near and its
    rows. `values`: fields whose text changed. `new`: other names that
    appeared. `gone`: how many items went. `moved`: how many that stayed
    moved. Items are counted, so a second copy of a name is new."""
    change = {}
    if before["window"] != after["window"]:
        change["window"] = after["window"]
    pairs, gone_items, added = _matched(
        [i for i in before["items"] if i["kind"] != "more"],
        [i for i in after["items"] if i["kind"] != "more"])
    # One more nameless label says nothing: a nameless kind is new only when none was there.
    counted = {f"{i['kind']}\x01" for i in before["items"] if not i["name"]}
    new, opened = [], {}
    for item in added:
        joined = f"{item['kind']}\x01{item['name']}"
        if joined in counted:
            continue
        counted.add(joined)
        if item.get("in"):
            if item["kind"] != "label" and item["name"]:
                opened.setdefault(item["in"], []).append(item)
            continue
        # Swift's split drops empty parts, so a nameless item shows its kind.
        parts = [p for p in joined.split("\x01") if p]
        if parts and parts[-1]:
            new.append(parts[-1])
    called = _fields(after)
    values = {called[id(b)]: b["value"] for a, b in pairs
              if id(b) in called and a["value"] != b["value"]}
    fields = [i for i in after["items"] if i["kind"] == "text" and not i.get("in")]
    appeared = []
    for kind, rows in opened.items():
        part = {"kind": kind, "rows": [r["name"] for r in rows]}
        first = min(rows, key=lambda r: (r["y"], r["x"]))
        # Outlook's list sat nearer Search than To, the field just typed in.
        if len(values) == 1:
            part["near"] = next(iter(values))
        elif fields:
            field = min(fields, key=lambda f: (f["x"] - first["x"]) ** 2 + (f["y"] - first["y"]) ** 2)
            part["near"] = field["name"] or field["role"].replace("AX", "")
        appeared.append(part)
    renamed = _renamed(gone_items, added)
    if renamed:
        change["renamed"] = renamed
        new = [n for n in new if n not in renamed.values()]
    gone = len(gone_items) - len(renamed)
    # Nameless twins pair by distance alone, so their moves mean nothing.
    moved = sum(1 for a, b in pairs if b["name"]
                and (abs(a["x"] - b["x"]) > MOVED or abs(a["y"] - b["y"]) > MOVED))
    focus = _focused(after)
    if focus is not None and focus != _focused(before):
        change["focus"] = focus
    states = {b["name"]: sorted(_states(b)) for a, b in pairs
              if b["name"] and _states(a) != _states(b)}
    if states:
        change["states"] = states
    if appeared:
        change["appeared"] = appeared
    if values:
        change["values"] = values
    if new:
        change["new"] = new
    if gone:
        change["gone"] = gone
    if moved:
        change["moved"] = moved
    blocks, still = seen_changes(before, after, values)
    if blocks:
        change["seen"] = blocks
    if still:
        change["still"] = still
    return change


def _renamed(gone, added):
    """Old name to new, for an item that stayed where it was and changed its
    name. Teams' "Search (⌘ E)" reads "Look for people, messages, files and
    more" once clicked, and the plan still said the old name."""
    out = {}
    for old in gone:
        for item in added:
            if item["role"] == old["role"] and item["name"] and old["name"] \
                    and item["name"] != old["name"] \
                    and abs(item["x"] - old["x"]) <= 20 and abs(item["y"] - old["y"]) <= 20 \
                    and item["name"] not in out.values():
                out[old["name"]] = item["name"]
                break
    return out


def _focused(snapshot):
    item = next((i for i in snapshot["items"] if "focused" in (i.get("state") or ())), None)
    if item is None:
        return None
    return item["name"] or item["role"].replace("AX", "")


# Seen lines: text read from the window's pixels at each read, in
# `snapshot["seen"]`. None when the app did not read it.
SAME_PLACE = 12   # points between two reads of the same line
BLOCK_GAP = 40    # points between the lines of one block
BLOCK_DRIFT = 40  # points the left edges of one block may differ
_WORD_RUN = re.compile(r"[^\W_]{2}")


def _plain(text):
    text = "".join(c for c in unicodedata.normalize("NFKD", str(text).lower())
                   if not unicodedata.combining(c))
    return " ".join(re.sub(r"[\W_]+", " ", text).split())


def same_text(seen, said):
    """Whether a seen line and a tree text say the same thing. Case, spaces
    and punctuation do not count. The line may be part of the tree text:
    Vision cuts a long label in two. The tree text may be part of the line
    when it is whole words and 60% of it: Vision reads "Q Search (% E)"
    for "Search (⌘ E)", and a row "Peter Holm" must not match "Peter"."""
    a, b = _plain(seen), _plain(said)
    if not a or not b:
        return False
    if f" {a} " in f" {b} ":
        return True
    return f" {b} " in f" {a} " and len(b) >= 0.6 * len(a)


def alike(seen, said):
    """Looser, for a line and a text at the same place: 70% of the line's
    characters in order in the text. Vision reads "23/09/26" as "23109126".
    Six characters at least: "18:30" over a field that holds "17:30" is not
    that field."""
    a, b = _plain(seen), _plain(said)
    if len(a) < 6 or not b:
        return False
    blocks = difflib.SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks()
    return sum(block.size for block in blocks) >= 0.7 * len(a)


def _texts(item):
    return [t for t in (item.get("name"), item.get("value")) if t]


def _in(items, line):
    """The item that holds the line's text: anywhere with `same_text`, at
    the same place with `alike`."""
    return next((i for i in items for t in _texts(i) if same_text(line["text"], t)
                 or _inside(line, i) and alike(line["text"], t)), None)


def noise(line):
    """Two characters or less, or no run of two letters or digits: initials
    in an avatar, a day in a calendar, an icon read as letters."""
    text = str(line.get("text") or "").strip()
    return len(text) <= 2 or not _WORD_RUN.search(text)


def _left(line):
    return line["x"] - line.get("w", 0) / 2


def _top(line):
    return line["y"] - line.get("h", 0) / 2


def _bottom(line):
    return line["y"] + line.get("h", 0) / 2


def _overlap(a, b):
    """The share of the smaller box that the two boxes have in common."""
    width = min(a["x"] + a.get("w", 0) / 2, b["x"] + b.get("w", 0) / 2) \
        - max(a["x"] - a.get("w", 0) / 2, b["x"] - b.get("w", 0) / 2)
    height = min(a["y"] + a.get("h", 0) / 2, b["y"] + b.get("h", 0) / 2) \
        - max(a["y"] - a.get("h", 0) / 2, b["y"] - b.get("h", 0) / 2)
    smaller = min(a.get("w", 0) * a.get("h", 0), b.get("w", 0) * b.get("h", 0))
    return width * height / smaller if width > 0 and height > 0 and smaller > 0 else 0


def _same_place(a, b):
    """Vision cuts a line at a different letter from one read to the next,
    and its centre moves: "O] Meet now" then "Meet now", 13 points apart."""
    return abs(a["x"] - b["x"]) <= SAME_PLACE and abs(a["y"] - b["y"]) <= SAME_PLACE \
        or _overlap(a, b) >= 0.5


def _was_seen(line, lines):
    return any(_same_place(line, o)
               and (same_text(line["text"], o["text"]) or same_text(o["text"], line["text"])
                    or alike(line["text"], o["text"]))
               for o in lines)


def _inside(line, item, margin=SAME_PLACE):
    return abs(line["x"] - item["x"]) <= item.get("w", 0) / 2 + margin \
        and abs(line["y"] - item["y"]) <= item.get("h", 0) / 2 + margin


def _line_of(line):
    return {"text": " ".join(str(line["text"]).split()),
            **{k: line.get(k, 0) for k in ("x", "y", "w", "h")}, "p": line.get("p")}


def seen_changes(before, after, values=None):
    """(blocks, still) from the seen lines of `after`. A block is text that
    is new and not in the tree: {near, lines}. `still` are controls of the
    read before that left the tree and are still on screen, where they were:
    Teams' date panel hides the rest of the form from the tree, not from view.
    Both empty when `after` has no seen lines."""
    lines = (after or {}).get("seen")
    if not lines:
        return [], []
    earlier = (before or {}).get("seen") or []
    now = [i for i in after["items"] if i["kind"] != "more"]
    # A new window is new everywhere, and the tree has it.
    moved = before is not None and before.get("window") != after.get("window")
    was = [i for i in (before or {}).get("items", ()) if i["kind"] != "more"]
    fresh, still, held = [], [], set()
    for line in lines:
        if not isinstance(line, dict) or noise(line) or _in(now, line):
            continue
        old = next((i for i in was if i["kind"] in ("click", "text") and _inside(line, i)
                    and any(same_text(line["text"], t) for t in _texts(i))), None)
        if old is not None:
            if id(old) not in held:
                held.add(id(old))
                still.append(dict(_line_of(line), role=old["role"].replace("AX", ""),
                                  name=old["name"]))
            continue
        if moved or _was_seen(line, earlier):
            continue
        fresh.append(_line_of(line))
    fresh.sort(key=lambda line: (line["y"], line["x"]))
    groups = []
    for line in fresh:
        group = next((g for g in groups
                      if -4 <= _top(line) - _bottom(g[-1]) <= BLOCK_GAP
                      and abs(_left(line) - _left(g[0])) <= BLOCK_DRIFT), None)
        if group is None:
            groups.append([line])
        else:
            group.append(line)
    fields = [i for i in now if i["kind"] == "text" and not i.get("in")]
    focused = next((i for i in fields if "focused" in (i.get("state") or ())), None)
    blocks = []
    for group in groups:
        block = {"lines": group}
        first = group[0]
        if values and len(values) == 1:
            block["near"] = next(iter(values))
        elif focused is not None:
            block["near"] = decider.label(focused)
        elif fields:
            field = min(fields, key=lambda f: (f["x"] - first["x"]) ** 2 + (f["y"] - first["y"]) ** 2)
            block["near"] = decider.label(field)
        blocks.append(block)
    return blocks, still


def still_there(line, snapshot):
    """Whether a line seen at an earlier read is at its place in this one,
    and still not in its tree."""
    return _was_seen(line, snapshot.get("seen") or ()) \
        and _in([i for i in snapshot["items"] if i["kind"] != "more"], line) is None


def covering(target, snapshot):
    """Seen lines over `target` that are not its own text and not in the
    tree: something the tree does not know lies over it. Seen 09-23: Start
    time's list lay over End time and the hit test still named End time. An
    empty field's one line is taken for its placeholder."""
    lines = snapshot.get("seen") or ()
    if not target.get("w") or not target.get("h"):
        return []
    left, right = target["x"] - target["w"] / 2, target["x"] + target["w"] / 2
    top, bottom = target["y"] - target["h"] / 2, target["y"] + target["h"] / 2
    over = []
    for line in lines:
        if not isinstance(line, dict) or noise(line):
            continue
        width = min(right, line["x"] + line["w"] / 2) - max(left, line["x"] - line["w"] / 2)
        height = min(bottom, line["y"] + line["h"] / 2) - max(top, line["y"] - line["h"] / 2)
        if width <= 0 or height <= 0 or width * height < 0.5 * line["w"] * line["h"]:
            continue
        if _in([target], line) or _in(snapshot["items"], line):
            continue
        over.append(_line_of(line))
    if len(over) == 1 and target["kind"] == "text" and not target.get("value"):
        return []
    return over


def _seen_line(line):
    text = f"\"{decider.prefix(line['text'], 60)}\""
    return f"[{line['id']}] {text}" if line.get("id") is not None else text


def _still_line(line):
    item = f"{line['role'] or 'Item'} \"{decider.prefix(line['name'] or line['text'], 40)}\""
    return f"[{line['id']}] {item}" if line.get("id") is not None else item


SEEN_SHOWN = 12


def sentence(change):
    """A change in a sentence. Names rather than counts: "the window is now
    Demo App (DM)" decides whether a step worked; 37 added and 41 removed
    does not."""
    out = []
    if "window" in change:
        out.append(f"the window is now \"{change['window']}\"")
    for part in change.get("appeared", ()):
        rows = ", ".join(f"\"{decider.prefix(r, 40)}\"" for r in part["rows"][:6])
        near = f" near \"{decider.prefix(part['near'], 30)}\"" if part.get("near") else ""
        out.append(f"a {part['kind']} opened{near}: {rows}")
    if "focus" in change:
        out.append(f"the caret is now in \"{decider.prefix(change['focus'], 40)}\"")
    for was, now in change.get("renamed", {}).items():
        out.append(f"\"{decider.prefix(was, 30)}\" now reads \"{decider.prefix(now, 40)}\"")
    for name, state in change.get("states", {}).items():
        out.append(f"\"{decider.prefix(name, 30)}\" is now {', '.join(state) or 'not selected'}")
    for name, value in change.get("values", {}).items():
        out.append(f"\"{decider.prefix(name, 30)}\" now holds \"{decider.prefix(value, 40)}\""
                   if value else f"\"{decider.prefix(name, 30)}\" is now empty")
    new = change.get("new", ())
    if new:
        names = ", ".join(f"\"{decider.prefix(n, 40)}\"" for n in new[:6])
        out.append(f"{len(new)} new: {names}")
    if change.get("gone"):
        out.append(f"{change['gone']} gone")
    if change.get("moved"):
        out.append(f"{change['moved']} moved")
    for block in change.get("seen", ()):
        near = f" near \"{decider.prefix(block['near'], 30)}\"" if block.get("near") else ""
        lines = ", ".join(_seen_line(line) for line in block["lines"][:SEEN_SHOWN])
        out.append(f"text appeared{near} (seen, not in the tree): {lines}")
    if change.get("still"):
        lines = ", ".join(_still_line(line) for line in change["still"][:SEEN_SHOWN])
        out.append(f"still on screen, no longer in the tree (a panel may be hiding them): {lines}")
    return "; ".join(out)


# Slack's To: holds "\xa0 Alex Moreau \xa0 \xa0": one name per run of spaces.
_PARTS = re.compile(r"[,;\n ]|\s{2,}")
_LETTERS = re.compile(r"[^\W\d_]{2}")


def _inside(item, field):
    return abs(item["x"] - field["x"]) <= field["w"] / 2 \
        and abs(item["y"] - field["y"]) <= field["h"] / 2


_LOOKS_UP = re.compile(r"\b(attendees?|to|cc|bcc|search|invite|recipients?|participants?|people)\b")


def looks_up(item):
    """A field that narrows a list as you type: To, a search box, a combo box."""
    return bool(item) and item["kind"] == "text" and item["role"] != "AXTextArea" and (
        item.get("lookup") or item["role"] in ("AXComboBox", "AXSearchField")
        or _LOOKS_UP.search(item["name"].lower()) is not None)


def suggested(field, before, after):
    """Whether a list opened under a lookup field between two reads: a
    part of the app, the field now expanded, or new items or seen lines
    below it. Seen 09-25 in Gmail: the contact row came as a new item, and
    To became expanded."""
    change = changes(before, after)
    if change.get("appeared") or "expanded" in change.get("states", {}).get(field["name"], ()):
        return True
    bottom = field["y"] + field["h"] / 2

    def below(p):
        return abs(p["x"] - field["x"]) <= field["w"] / 2 + LIST_SIDE \
            and bottom - 4 < p["y"] <= bottom + LIST_BELOW
    return any(i.get("in") or i.get("in_list") or i["kind"] != "text" and i["name"] and below(i)
               for i in appeared(before, after)) \
        or any(below(line) for block in change.get("seen", ()) for line in block["lines"])


def no_list(typed):
    return f"no list showed for \"{decider.prefix(typed, 40)}\""


_RECIPIENT = re.compile(r"\b(to|cc|bcc|recipients?|attendees?|invitees?|participants?)\b")
_EMAIL = re.compile(r"[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+")
# A picked contact is drawn in the field's value as U+FFFC (Outlook) or
# between no-break spaces (Slack); typed text comes after the last one.
_CHIP = re.compile("[\ufffc\xa0]")


def typed_text(value):
    """The text typed after the last picked contact in a field's value."""
    parts = _CHIP.split(value or "")
    if len(parts) > 1 and not parts[-1].strip():
        parts.pop()
    return " ".join(parts[-1].split())


def takes_recipients(item):
    return looks_up(item) and _RECIPIENT.search(item["name"].lower()) is not None


def is_address(text):
    words = [w for w in re.split(r"[,;\s]+", text or "") if w]
    return bool(words) and all(_EMAIL.fullmatch(w) for w in words)


def lookup_text(value, letters):
    """What to type into a recipient field to open its list: the first word,
    cut to `letters` when more than 0. An email address goes in whole.
    Seen 09-25 in Gmail: "Sonia" listed "Bonell-Granda Sonia"; "Sonia
    Bonnell" closed the list at the second n."""
    if is_address(value):
        return value
    first = re.split(r"[\s,;]+", value.strip())[0]
    return first[:letters] if letters > 0 else first


def not_a_recipient(item):
    """The typed text a recipient field holds that is not an email address,
    or "". Seen 09-25 in Gmail: a picked contact left To's value empty; the
    unmatched "Sonia Bonnell" stayed in it as text, and the run ended done."""
    typed = typed_text(item["value"])
    return "" if not typed or is_address(typed) else typed


def unresolved_line(label, typed):
    return (f"\"{decider.prefix(label, 40)}\" still holds the text \"{decider.prefix(typed, 40)}\", "
            "which is not a recipient: pick the contact from the list or type an email address")


def _texts_in(field, snapshot):
    return [field["value"]] + [i["name"] or i["value"] for i in snapshot["items"]
                               if i is not field and i["kind"] != "text" and _inside(i, field)]


def holds(field, snapshot):
    """What a text field holds as the walk read it: its value, then the
    items drawn inside it. The walk reads no text area's value; a Chrome
    body shows its paragraphs as items inside it. Its own name, a
    placeholder, is not held."""
    return "\n".join(t for t in _texts_in(field, snapshot)
                     if t and t.strip() and _plain(t) != _plain(field["name"]))


def find_words(text, words):
    """Where `words` are in `text`, as (start, end) pairs: exactly, else with
    case and runs of spaces not counting."""
    words = (words or "").strip()
    if not words:
        return []
    found = [(m.start(), m.end()) for m in re.finditer(re.escape(words), text)]
    if found:
        return found
    pattern = r"\s+".join(re.escape(w) for w in words.split())
    return [(m.start(), m.end()) for m in re.finditer(pattern, text, re.IGNORECASE)]


def _utf16(text):
    """The length the app counts in: UTF-16 units."""
    return len(text.encode("utf-16-le")) // 2


def lost(field, before, after):
    """The names and words a step took out of `field`, a text field of the
    read before it: from its value, or from the items drawn inside it.
    Numbers and the field's own name, a placeholder, do not count. Over 72
    recorded steps with a target (09-23), 3 fired: each had removed a
    recipient."""
    same = [i for i in after["items"]
            if (i["kind"], i["role"], i["name"]) == (field["kind"], field["role"], field["name"])]
    if field["kind"] != "text" or not same:
        return []
    now = min(same, key=lambda i: (i["x"] - field["x"]) ** 2 + (i["y"] - field["y"]) ** 2)
    kept = " ".join(_plain(t) for t in _texts_in(now, after))
    out = []
    for text in _texts_in(field, before):
        for part in _PARTS.split(text or ""):
            part = " ".join(part.split())
            plain = _plain(part)
            if _LETTERS.search(part) and plain != _plain(field["name"]) \
                    and f" {plain} " not in f" {kept} " and part not in out:
                out.append(part)
    return out


class Loop:
    def __init__(self, request, channel, jev, planner=None):
        self.request = request
        self.channel = channel
        self.jev = jev
        self.planner = planner
        self.utterance = request.get("run", "")
        settings = request.get("loop") or {}
        self.max_steps = int(settings.get("max_steps", 30))
        self.lookup_letters = int(settings.get("lookup_letters", 0))
        self.spotlight = float(settings.get("spotlight", 0))
        self.execute = request.get("execute", True)
        self.app = request.get("read_app")
        self.change = {}
        # The field the last `caret` or `select` put the caret in, by identity.
        self.placed = None
        # The last type or write went where `caret` or `select` put the caret.
        self.typed_placed = False
        # The last type into a lookup field ended with no list showing.
        self.unsuggested = False
        # Recipient fields read in this run, by identity: (label, typed text
        # that is not a recipient). Kept when the field leaves the tree:
        # Gmail folds To away once the caret leaves it.
        self.recipients = {}
        # The text field the last step acted in, by identity.
        self.last_field = None
        self.recorder = getattr(channel, "recorder", recording.OFF)
        self.agent = None
        self.began, self.reads = time.monotonic(), 0

    # Talking to the app

    def call(self, do, **args):
        """One step. A said error (Escape, a refusal, the app not in front)
        ends the run with its text; any other error comes back in the reply."""
        if do == "key":
            args.update(self._progress())
        reply = self.channel.ask(do, **args)
        if reply.get("error") and reply.get("said"):
            if reply["error"] == "escape":
                raise Stop(ESCAPED)
            raise Stop(reply.get("text") or reply["error"])
        return reply

    def log(self, line):
        self.call("log", text=line, plain=True)

    def show(self, now=False, **fields):
        """The run panel's state (see `progress` in runner.py)."""
        progress = getattr(self.channel, "progress", None)
        if progress is not None:
            progress(now=now, **fields)

    def say(self, line):
        self.call("say", text=line)

    # The run

    def run(self):
        report = Report()
        self.report = report
        self.recorder.update(kind="agent")
        try:
            if self.planner is None:
                raise Stop(NO_PLANNER, broke=True)
            if self.planner.loop != "agent":
                self.log(f"action loop: loop \"{self.planner.loop}\" is gone; running the agent")
            import agent
            self.agent = agent.Agent(self)
            self.agent.run(report)
        except Stop as stop:
            report.stopped = stop.text
            report.broke = report.broke or stop.broke
            if stop.text != ESCAPED:
                try:
                    self.log(f"action loop: stopped — {stop.text}")
                except Stop:
                    pass
        except (decider.Failure, planning.Failure) as failure:
            report.stopped = str(failure)
            report.broke = True
            try:
                self.log(f"action loop: failed — {report.stopped}")
            except Stop:
                pass
        finally:
            if self.spotlight > 0 and self.execute:
                try:
                    self.channel.ask("spotlight_dismiss")
                except Exception:
                    pass
        if self.agent is not None and report.ending() in ("stopped", "failed"):
            self.agent._note(report.stopped)
        return report

    def _read(self, aim, app):
        """The window, with `seen`, its text read from the pixels, when the
        app read it, and `focus` and `ready_box` from the same read."""
        reply = self.call("observe", app=app, see=True)
        if reply.get("error"):
            raise Stop(reply["error"], broke=True)
        snapshot = reply["snapshot"]
        for item in snapshot["items"]:
            if takes_recipients(item):
                self.recipients[identity(item)] = (decider.label(item), not_a_recipient(item))
        if isinstance(reply.get("seen"), list):
            snapshot["seen"] = reply["seen"]
        if isinstance(reply.get("focus"), dict):
            snapshot["focus"] = reply["focus"]
            snapshot["ready_box"] = reply.get("ready_box")
        # Its picture, for `ground`: {file, frame, scale, w, h}.
        if isinstance(reply.get("shot"), dict) and reply["shot"].get("file"):
            snapshot["shot"] = reply["shot"]
        return snapshot

    def settle(self, before, aim, policy, until=None):
        """The window once the app has answered a gesture: the first read for
        which `until(read)` holds (by default: it differs from `before`), or
        the first read that starts once the policy's time is up."""
        until = until or (lambda now: bool(changes(before, now)))
        at_most = SETTLE[policy]
        began = time.monotonic()
        n = 0
        while True:
            n += 1
            wait = began + min(n * SETTLE_EVERY, at_most) - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            started = time.monotonic() - began
            now = self._read(aim, before["app"])
            self.reads += 1
            if until(now) or started >= at_most - 0.01:
                return now

    def _find(self, step, snapshot):
        """The planned target on screen, or why not. Raises Stop when its
        words are nowhere in what was read: a seeing failure, not re-planned."""
        words = step["target"]
        renamed = getattr(self, "renamed", {})
        while words in renamed:
            words = renamed.pop(words)
            self.log(f"planner: “{step['target']}” now reads “{words}”")
        among = decider.candidates(snapshot, f"{self.utterance} {words}")
        question = f"Which of these is “{words}”?"
        item, p, ms = decider.pick(self.jev, question, among, snapshot, self.utterance)
        self.among = among
        print(f"jev pick {ms} ms")
        if item is None:
            if not decider.words_seen(words, snapshot):
                self.log(f"planner: target not in the tree: \"{words}\" — {snapshot['app']} "
                         f"“{snapshot['window']}”, {len(snapshot['items'])} items")
                raise Stop(f"Could not find “{decider.prefix(words, 40)}” on screen")
            self.log(f"planner: none of {len(among)} is “{words}” ({p:.2f})")
            return None, f"none of the {len(among)} items offered is “{words}”"
        self.log(f"planner: “{words}” → {decider.short(item, snapshot)}, {p:.2f}, of {len(among)}")
        if p < PICK_FLOOR:
            return None, f"“{words}” picked {decider.short(item, snapshot)} at only {p:.2f}"
        return item, None

    def _progress(self):
        """The steps done so far, for the app's question panel. The app asks
        its own questions before a key or a press, so those carry them too."""
        report = getattr(self, "report", None)
        return {"shown": report.shown[-4:]} if report and report.shown else {}

    def ask(self, question, options, near=None):
        """(the user's answer or None, how it came). The app shows the question
        in a panel next to `near`. Escape ends the run."""
        self.show(now=True, activity="asking you…")
        reply = self.channel.ask("ask", question=question, options=list(options), near=near,
                                 **self._progress())
        if reply.get("error") == "escape" or reply.get("via") == "escape":
            raise Stop(ESCAPED)
        if reply.get("error") and reply.get("said"):
            raise Stop(reply.get("text") or reply["error"])
        answer = reply.get("answer")
        answer = answer.strip() if isinstance(answer, str) else ""
        via = reply.get("via") or "timeout"
        self.log(f"asked: {decider.prefix(question, 120)} — "
                 + (f"{via}: {decider.prefix(answer, 120)}" if answer else f"no answer ({via})"))
        return answer or None, via

    def _allowed(self, question, near=None):
        """The answer to a step a guard would refuse, as `verdict` reads it:
        YES, None for no (no answer is no), or other words."""
        answer, _ = self.ask(question, [YES, "No"], near)
        return verdict(answer)

    @staticmethod
    def _refused(answer, why):
        """A guard's no is `why`; other words are what the user said instead."""
        return redirected(answer) if answer else why

    def _press(self, item, click):
        """A press, or why it failed. A refused press is a reason to re-plan,
        not the end of the run."""
        reply = self.channel.ask("press", id=item["id"], click=click, **self._progress())
        if reply.get("error") == "escape":
            raise Stop(ESCAPED)
        if reply.get("error") == "refused":
            return "the app refused to press it"
        if reply.get("error") == "redirected":
            return redirected(reply.get("text") or "")
        if reply.get("error") and reply.get("said"):
            raise Stop(reply.get("text") or reply["error"])
        if reply.get("error"):
            return reply["error"]
        return None

    def _caret_in(self, target, snapshot):
        """Whether the caret is already in `target`: then typing needs no click."""
        if "focused" in (target.get("state") or ()):
            return True
        focus = self._focus(snapshot)
        if focus.get("id") is not None and focus["id"] == target.get("id"):
            return True
        point = focus.get("point")
        if not point:
            return False
        x, y = point
        return abs(x - target["x"]) <= target["w"] / 2 + 2 and abs(y - target["y"]) <= target["h"] / 2 + 2

    def _focus(self, snapshot):
        """Where the caret was when `snapshot` was read: {point, role, id}.
        Asked for when the read did not carry it."""
        return snapshot.get("focus") or self.call("focus", app=snapshot["app"])

    def _click_at(self, target):
        """A real click at the centre of a line `look` saw: it has no element
        to press. As `_press`, a refusal is a reason to try another way."""
        reply = self.channel.ask("click_at", x=target["x"], y=target["y"], name=target["name"],
                                 **self._progress())
        if reply.get("error") == "escape":
            raise Stop(ESCAPED)
        if reply.get("error") == "refused":
            return "the app refused to click it"
        if reply.get("error") and reply.get("said"):
            raise Stop(reply.get("text") or reply["error"])
        return reply.get("error")

    def _planned_step(self, step, snapshot, aim, report, item=None):
        """One planned step. (why it failed or None, the window now, aim, what changed).
        `item` is the target when the caller already knows it; otherwise Jev
        finds `step["target"]`."""
        self.show(activity=planning.doing(step))
        self.recorder.begin_step(step, item)
        self.began, self.reads = time.monotonic(), 0
        try:
            why, now, aim, outcome = self._step(step, snapshot, aim, report, item)
        except Stop as stop:
            self.recorder.end_step(error=stop.text, shown=report.shown)
            raise
        except Exception as error:
            self.recorder.end_step(error=f"{type(error).__name__}: {error}", shown=report.shown)
            raise
        if why is None:
            self.recorder.end_step(change=self.change, sentence=sentence(self.change),
                                   outcome=outcome, shown=report.shown)
        else:
            self.recorder.end_step(why=why, shown=report.shown)
        return why, now, aim, outcome

    def _step(self, step, snapshot, aim, report, item):
        do, value = step["do"], step["value"]
        target = typed_on = None
        closed = ""
        self.target_kind = None
        self.unsuggested = False
        # What a type into a recipient field typed, when not the whole value.
        self.cut = ""
        if do == "type":
            said = decider.said_words(self.utterance)
            unsaid = [w for w in decider._words(value)
                      if len(w) > 2 and w not in said
                      and not decider.words_seen(w, snapshot)]
            answer = unsaid and self._allowed(
                f"Type “{decider.prefix(value, 40)}”? You did not say {', '.join(unsaid[:4])}",
                frame(item))
            if unsaid and answer != YES:
                return (self._refused(answer, "would type words that were not said: "
                                      + ", ".join(unsaid[:4])), snapshot, aim, "")
        if do == "key" and value == "cmd+a":
            why = self._select_all(self._focus(snapshot).get("role"))
            if why:
                return why, snapshot, aim, ""
        at = step.get("at")
        field = held = None
        moved = ""
        self.typed_placed = False
        # The caret leaves the field a caret or select put it in.
        if do in ("click", "pick", "scroll") \
                or do == "key" and value.split("+")[-1] in ("tab", "escape", "return") \
                or item is not None and identity(item) != self.placed:
            self.placed = None
        why = self._edit_problem(do, at, value)
        if why:
            return why, snapshot, aim, ""
        if do == "key":
            self.front()
            reply = self.call("key", keys=value, wait=400)
            if reply.get("error") == "redirected":
                return redirected(reply.get("text") or ""), snapshot, aim, ""
            if reply.get("error"):
                return f"could not press {value}: {reply['error']}", snapshot, aim, ""
        elif do == "scroll":
            target = item
            if item is None and step["target"]:
                try:
                    target, why = self._find(step, snapshot)
                except Stop:
                    target = None
            window = snapshot["frame"]
            spot = (decider.point(target) if target else aim
                    or [window["x"] + window["w"] // 2, window["y"] + window["h"] // 2])
            self.act("scroll", x=spot[0], y=spot[1], down=value.lower() != "up", turns=6)
        elif do in ("caret", "select") and item is None \
                and step["target"].lower() in ("", "no name"):
            field = self._focused_item(snapshot)
            if field is None or field["kind"] != "text":
                return "no text field has the caret: give the field's ID", snapshot, aim, ""
            self.front()
            why, moved = self._edit(do, field, at, value)
            if why:
                return why, snapshot, aim, ""
        elif do in ("type", "write") and item is None \
                and step["target"].lower() in ("", "no name"):
            if not value:
                return "nothing to type", snapshot, aim, ""
            field = self._focused_item(snapshot)
            held, why = self._where(field, snapshot, at)
            if why:
                return why, snapshot, aim, ""
            self.front()
            why = self._place(field, at, snapshot)
            if why:
                return why, snapshot, aim, ""
            self.act("paste" if do == "write" else "type",
                     text=self._typing(do, field, at, held, value))
        else:
            target, why = (item, None) if item is not None else self._find(step, snapshot)
            if target is None:
                return why, snapshot, aim, ""
            self.target_kind = target["kind"]
            if do in ("type", "write") and target["kind"] == "text":
                field = target
                held, why = self._where(field, snapshot, at)
                if why:
                    return why, snapshot, aim, ""
            if do in ("caret", "select") and target["kind"] != "text":
                return f"\"{decider.label(target)}\" is not a text field", snapshot, aim, ""
            snapshot, closed, why = self._close_open_list(target, snapshot, aim)
            if why:
                return why, snapshot, aim, ""
            why = self._covered(target, snapshot)
            if why:
                return why, snapshot, aim, ""
            if self.spotlight > 0 and target["kind"] != "seen":
                self.call("spotlight", snapshot=snapshot["id"],
                          offers=[o["id"] for o in getattr(self, "among", [])],
                          aim=aim, chosen=target["id"], seconds=self.spotlight)
                time.sleep(self.spotlight)
                self.call("spotlight_dismiss")
            # Teams' search results and Outlook's suggestions: pressing the
            # row closed the list and chose nobody. A real click chose.
            fresh = (target["kind"], target["name"]) in self.fresh
            pressed = True
            if target["kind"] == "seen":
                self.front()
                why = self._click_at(target)
            elif do in ("type", "write", "caret", "select") and (
                    self._caret_in(target, snapshot) or self.placed == identity(target)):
                # Seen 09-23 in Slack: clicking To's centre selected the first
                # recipient's chip, and typing the second name replaced it.
                why, pressed = None, False
            else:
                why = self._press(target, click=bool(target.get("in_list") or target.get("in")
                                                     or fresh or target["role"] == "AXStaticText"))
            if why:
                return why, snapshot, aim, ""
            if do in ("type", "write"):
                if not value:
                    return "nothing to type", snapshot, aim, ""
                if pressed:
                    typed_on = self.settle(snapshot, aim, "before_type")
                self.front()
                why = self._place(field, at, typed_on or snapshot)
                if why:
                    return why, typed_on or snapshot, aim, ""
                # Key presses for `type`, the paste for `write`. Seen 09-23 in
                # Outlook: the time field's hour ignored a pasted "11" three times.
                self.act("type" if do == "type" else "paste",
                         text=self._typing(do, field, at, held, value))
            elif do in ("caret", "select"):
                if pressed:
                    typed_on = self.settle(snapshot, aim, "before_type")
                self.front()
                why, moved = self._edit(do, refind(target, typed_on) or target if typed_on
                                        else target, at, value)
                if why:
                    return why, typed_on or snapshot, aim, ""
        report.acted = True
        # Teams' attendee list came late after typing. Settled against the
        # read after the press, so the press's focus change does not end it.
        policy = "after_key" if do in ("key", "caret", "select") else \
            "after_type" if do in ("type", "write") else "after_press"
        until = None
        # The field's own value changes first; the list comes after.
        if do == "type" and looks_up(field):
            policy, until = "lookup", lambda read: suggested(field, snapshot, read)
        now = self.settle(typed_on or snapshot, aim, policy, until)
        self.unsuggested = until is not None and now.get("seen") is not None \
            and not until(now)
        change = changes(snapshot, now)
        changed = sentence(change)
        self.fresh = {(i["kind"], i["name"]) for i in appeared(snapshot, now)}
        self.renamed.update(change.get("renamed", {}))
        # Chrome and Notion answer AXPress and do nothing: one real click.
        if not changed and do in ("click", "pick") and target is not None \
                and not target.get("in_list") and target["kind"] != "seen":
            self.log("planner: the press did nothing; clicking for real")
            why = self._press(target, click=True)
            if why:
                return why, now, aim, ""
            now = self.settle(now, aim, "after_press")
            change = changes(snapshot, now)
            changed = sentence(change)
        self.change = change
        self._forget_placed(now)
        if do in ("type", "write") and field is not None:
            why = self._typed(refind(field, now) or field, at, value, held)
            if why:
                return why, now, aim, ""
        outcome = changed or UNCHANGED
        if moved:
            outcome = f"{moved}; {changed}" if changed else moved
        if self.unsuggested:
            outcome = f"{no_list(self.cut or value)}; {outcome}"
        if self.cut:
            outcome = (f"typed \"{self.cut}\" of \"{decider.prefix(value, 40)}\" to open the "
                       f"list: pick the row; {outcome}")
        acted = field or target
        if acted is not None and acted["kind"] == "text":
            label, typed = self.recipients.get(self.last_field, ("", ""))
            if typed and identity(acted) != self.last_field:
                outcome = f"{unresolved_line(label, typed)}; {outcome}"
            self.last_field = identity(acted)
        if closed:
            outcome = f"{closed}; {outcome}"
        ms = int((time.monotonic() - self.began) * 1000)
        self.log(f"planner: changed ({ms} ms, {self.reads} reads) — {decider.prefix(outcome, 160)}")
        said = planning.describe_step(dict(step, expect=""))
        report.steps.append(f"{said}; {decider.prefix(outcome, 120)}")
        report.shown.append(self._shown(step))
        focus = self._focus(now).get("point")
        if focus:
            aim = focus
        elif target is not None:
            aim = decider.point(target)
        return None, now, aim, outcome

    def unresolved(self):
        """A line per recipient field that holds typed text, not a recipient."""
        return [unresolved_line(label, typed) + "." for label, typed in self.recipients.values() if typed]

    def _forget_placed(self, snapshot):
        """Forgets the field a caret or select placed the caret in once it is
        gone, or another item has the focus. Not on a new window title: Gmail
        renames the window when it saves the draft, 09-25."""
        if self.placed is None:
            return
        focused = next((i for i in snapshot["items"] if "focused" in (i.get("state") or ())), None)
        if not any(identity(i) == self.placed for i in snapshot["items"]) \
                or focused is not None and identity(focused) != self.placed:
            self.placed = None

    def _close_open_list(self, target, snapshot, aim):
        """(the window now, what was done, why it failed): Return in an open
        list that is not the target's. Seen 09-23 in Teams: Start time's list
        lay over End time, the hit test still named End time, and the click
        picked 18:30 in Start time. Escape reverted the time; Return keeps it."""
        if target["kind"] == "seen" or target.get("in") or target.get("in_list"):
            return snapshot, "", None
        # Only when moving to another field. Seen 09-23 in Slack: the target
        # was a row of To's own list, Return closed it, and the click opened
        # whatever lay under the row.
        if target["kind"] != "text" and target["role"] not in OPENS_A_LIST:
            return snapshot, "", None
        spot = (target["role"], target["name"], target["x"], target["y"])
        open_list = next((i for i in snapshot["items"]
                          if "expanded" in (i.get("state") or ())
                          and (i["role"] in OPENS_A_LIST or i["kind"] == "text")
                          and i.get("id") != target.get("id")
                          and (i["role"], i["name"], i["x"], i["y"]) != spot), None)
        if open_list is None:
            return snapshot, "", None
        closed = f"closed the open list of \"{decider.label(open_list)}\" first"
        self.log(f"planner: {closed}")
        self.front()
        reply = self.call("key", keys="return", wait=300)
        if reply.get("error") == "redirected":
            return snapshot, "", redirected(reply.get("text") or "")
        if reply.get("error"):
            return snapshot, "", f"could not close the open list: {reply['error']}"
        return self._read(aim, snapshot["app"]), closed, None

    def _covered(self, target, snapshot):
        """Why not to act on `target`: text the tree does not hold lies over
        it. The app's hit test cannot see a web pop-up. Only for controls a
        line high: a text area holds text of its own."""
        if target["kind"] == "seen" or target.get("in") or target.get("in_list") \
                or target.get("h", 0) > COVER_HEIGHT:
            return None
        # Only while another control's list is open. Seen 09-23 in Slack:
        # To's own placeholder, "#a-channel, @somebody, or somebody@…", was
        # taken for a cover, and every type into To was refused.
        # A field's list, not any expanded control: Slack's "Chat with
        # Slackbot AI" button is always expanded.
        if not any("expanded" in (i.get("state") or ()) and i.get("id") != target.get("id")
                   and (i["role"] in OPENS_A_LIST or i["kind"] == "text")
                   and (i["role"], i["name"]) != (target["role"], target["name"])
                   for i in snapshot["items"]):
            return None
        over = covering(target, snapshot)
        if not over:
            return None
        why = (f"\"{decider.label(target)}\" is covered by text seen on screen: "
               + ", ".join(f"\"{decider.prefix(line['text'], 30)}\"" for line in over[:4]))
        self.log(f"planner: not clicked — {why}")
        return why

    def _select_all(self, role):
        """Why ⌘A may not run, or None. Asked, except in a one-line field."""
        if role in ONE_LINE:
            self.log(f"planner: ⌘A in a one-line field ({role}), not asked")
            return None
        answer = self._allowed("Select all?")
        if answer != YES:
            return self._refused(answer, "select all would put existing text at risk")
        return None

    def _focused_item(self, snapshot):
        """The item the caret is in, or None."""
        wanted = self._focus(snapshot).get("id")
        return next((i for i in snapshot["items"] if wanted is not None and i.get("id") == wanted
                     or "focused" in (i.get("state") or ())), None)

    def _field_text(self, field):
        """The field's whole text as the app reads it, or None when it cannot.
        The app finds the field at its box. Seen 09-25 in Gmail: a press on
        Subject folded To away, Subject moved up 32 points, and its old box
        hit the body: "Subject" read back the signature. So `field` must come
        from the newest read, and a field of another role is not read."""
        args = {"id": field["id"]} if field and field.get("id") is not None else {}
        reply = self.call("field_text", **args)
        text = reply.get("text")
        if field and reply.get("role") and reply["role"] != field["role"]:
            return None
        return text if isinstance(text, str) else None

    def _where(self, field, snapshot, at):
        """(what `field` holds, why a type or write may not run). Refused
        without a keystroke when the field holds text, the caret is not in
        it, and `at` does not say where the words go. Seen 09-25 in Gmail:
        the body held the signature and the message landed after it. With
        the caret in the field, the words go at the caret. What it holds is
        the app's whole text, or else the walk's, cut, with `partial` set."""
        # A date or time field takes typing over one part: Outlook's hour.
        if field is None or field["kind"] != "text" or looks_up(field) \
                or field["role"] == "AXDateTimeArea":
            return None, None
        self.typed_placed = not at and (self.placed == identity(field)
                                        or self._caret_in(field, snapshot))
        text = self._field_text(field)
        held = {"text": text, "partial": False} if text is not None \
            else {"text": holds(field, snapshot), "partial": True}
        if at or self.typed_placed or not held["text"].strip():
            return held, None
        shown = decider.prefix(" ".join(held["text"].split()), 60)
        return held, (f"\"{decider.label(field)}\" already holds \"{shown}\". Say where the "
                      "text goes: at start, end or replace.")

    def _place(self, field, at, snapshot):
        """Puts the caret where `at` says, in the focused field. Why not, or None."""
        if at in ("start", "end"):
            keys = "cmd+up" if at == "start" else "cmd+down"
            reply = self.call("key", keys=keys, wait=100)
            return f"could not press {keys}: {reply['error']}" if reply.get("error") else None
        if at == "replace":
            role = field["role"] if field else self._focus(snapshot).get("role")
            why = self._select_all(role)
            if why:
                return why
            reply = self.call("key", keys="cmd+a", wait=100)
            return f"could not press cmd+a: {reply['error']}" if reply.get("error") else None
        return None

    @staticmethod
    def _edit_problem(do, at, value):
        """Why a step's `at` and `value` do not go together, or None."""
        if do in ("type", "write") and at in ("before", "after"):
            return f"{do} takes at start, end or replace: put the caret {at} the words first"
        if do == "caret" and at not in ("start", "end", "before", "after"):
            return "caret needs at: start, end, before or after"
        if do == "caret" and at in ("before", "after") and not (value or "").strip():
            return f"caret {at} needs `value`, the words the field holds"
        if do == "select" and not (value or "").strip():
            return "select needs `value`, the words to select"
        return None

    def _edit(self, do, field, at, value):
        """`caret` or `select` in `field`, which has the caret. The model
        names words; code finds them in the field's whole text and the app
        moves the caret, then reads the selection back. Seen 09-25 in Gmail:
        nine `ground` calls to aim a caret between two digits.
        (why not, what was done)."""
        label = decider.label(field)
        if do == "caret" and at in ("start", "end"):
            keys = "cmd+up" if at == "start" else "cmd+down"
            reply = self.call("key", keys=keys, wait=100)
            if reply.get("error"):
                return f"could not press {keys}: {reply['error']}", ""
            self.placed = identity(field)
            return None, f"the caret is at the {at} of \"{label}\""
        text = self._field_text(field)
        if text is None:
            return f"could not read what \"{label}\" holds", ""
        words = value.strip()
        spans = find_words(text, words)
        if not spans:
            return (f"no \"{decider.prefix(words, 40)}\" in \"{label}\": it holds "
                    f"\"{decider.prefix(' '.join(text.split()), 80)}\""), ""
        if len(spans) > 1:
            around = ", ".join("\"…" + " ".join(text[max(0, s - 20):e + 20].split()) + "…\""
                               for s, e in spans[:4])
            return (f"\"{decider.prefix(words, 40)}\" is in \"{label}\" {len(spans)} times: "
                    f"{around}. Give more of the words around it."), ""
        start, end = spans[0]
        found = text[start:end]
        reply = self.call("select_text", id=field.get("id"), location=_utf16(text[:start]),
                          length=_utf16(found), text=found, caret=at if do == "caret" else None)
        if reply.get("error"):
            doing = "place the caret" if do == "caret" else "select"
            return f"could not {doing} in \"{label}\": {reply['error']}", ""
        self.placed = identity(field)
        by = " (by keys)" if reply.get("method") == "keys" else ""
        if do == "caret":
            return None, f"the caret is {at} \"{decider.prefix(found, 40)}\"{by}"
        return None, f"\"{decider.prefix(found, 40)}\" is selected{by}"

    def _typing(self, do, field, at, held, value):
        """The text a type or write sends."""
        if do == "type" and field is not None and takes_recipients(field):
            typed = lookup_text(value, self.lookup_letters)
            self.cut = typed if typed != value else ""
            return typed
        return self._paragraph(do, field, at, held, value)

    @staticmethod
    def _paragraph(do, field, at, held, value):
        """A body written at the start or end of what a text area holds is
        its own paragraph. Seen 09-25: "…78 11Bonjour Madame"."""
        text = (held or {}).get("text") or ""
        if do != "write" or not field or field["role"] != "AXTextArea" or not text.strip():
            return value
        if at == "start" and not value.endswith("\n"):
            return value + "\n"
        if at == "end" and not text.endswith("\n") and not value.startswith("\n"):
            return "\n" + value
        return value

    def _typed(self, field, at, value, held):
        """Why the text is not where `at` put it, read back from the field.
        None when it is, or when the app cannot read the field. Only where
        the place matters: a one-line field may show the text in its own
        format, 16:00 for "4 PM"."""
        if looks_up(field) or at not in ("start", "end") \
                and not (at == "replace" and field["role"] == "AXTextArea"):
            return None
        now = self._field_text(field)
        if now is None:
            return None
        norm = lambda text: " ".join((text or "").split())
        typed, after = norm(value), norm(now)
        before = norm(held["text"]) if held and not held["partial"] else ""
        shown = decider.prefix(after, 80)
        if typed not in after:
            return f"the text is not in \"{decider.label(field)}\" after typing: it holds \"{shown}\""
        if at == "start" and not after.startswith(typed) \
                or at == "end" and not after.endswith(typed):
            return f"the text is not at the {at} of \"{decider.label(field)}\": it holds \"{shown}\""
        if at != "replace" and before and before not in after.replace(typed, "", 1):
            return (f"\"{decider.label(field)}\" lost some of what it held: it held "
                    f"\"{decider.prefix(before, 60)}\" and now holds \"{shown}\"")
        return None

    @staticmethod
    def _shown(step):
        do, target, value = step["do"], step["target"], step["value"]
        if do == "key":
            return f"Pressed {value}"
        if do == "scroll":
            return f"Scrolled {value or 'down'}"
        if do == "caret":
            at = step.get("at")
            return f"Put the caret {at} “{decider.prefix(value, 40)}”" if value \
                else f"Put the caret at the {at}"
        if do == "select":
            return f"Selected “{decider.prefix(value, 40)}”"
        if do in ("type", "write"):
            return f"Typed “{decider.prefix(value, 40)}”" + (f" into {target}" if target else "")
        return f"Clicked {target}"

    # Doing one step

    def act(self, do, **args):
        """A step whose unsaid error ends the run as broken. Words the user
        said to a guard end it too: this path has no model to hand them to."""
        reply = self.call(do, **args)
        if reply.get("error") == "redirected":
            raise Stop(redirected(reply.get("text") or ""))
        if reply.get("error"):
            raise Stop(reply.get("text") or reply["error"], broke=True)
        return reply

    def front(self):
        """A chord goes to whatever is frontmost. ⌘N for a Slack message once
        opened a terminal window instead."""
        self.act("front")


def run(request, channel, jev, planner=None):
    """The loop for one request. Returns (how it ended, the report)."""
    report = Loop(request, channel, jev, planner).run()
    return report.ending(), report


def decide_only(request, jev, log):
    """`--act`: a decision on a snapshot the app hands over. Nothing is done."""
    utterance = request.get("decide", "")
    snapshot = request["snapshot"]
    offers = decider.candidates(snapshot, utterance)
    where = {id(item): index for index, item in enumerate(snapshot["items"])}
    described = [{"index": where[id(o)], "described": decider.describe(o, snapshot)}
                 for o in offers]
    reply = {"offers": described}
    mode = request.get("mode", "decide")
    notes = decider.notes_of(snapshot["app"], log)
    if mode == "request":
        reply["body"] = jev.body(*decider.request(utterance, snapshot, offers,
                                                  done=request.get("done") or (), notes=notes))
        return reply
    if mode == "look":
        return reply
    decision = decider.decide(jev, utterance, snapshot, done=request.get("done") or (), notes=notes)
    target = decision.target
    reply["decision"] = {
        "line": decision.line, "ms": decision.ms, "input_tokens": decision.input_tokens,
        "action": decision.action, "text": decision.text,
        "target": None if target is None else {
            "described": decider.describe(target, snapshot), "x": target["x"], "y": target["y"]},
    }
    return reply
