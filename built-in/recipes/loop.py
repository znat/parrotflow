"""The loop: one request, as many steps as it takes, when no recipe fits.

Read the window, ask Jev for one step, do it, read the window again. Jev is
never asked for a plan. It is told what was done and what changed, which
is the only way it can tell a step that worked from one that did nothing.

Ways out, in the order they are checked: Escape; nothing changed twice; the
same step asked for three times; `finished` over 0.5; action `none`; a step
that cannot act; the caret waiting for words; `max_steps`.

With a planner configured, `_planned` runs instead: the planner gives the
steps, Jev only finds each target, and the planner is asked again once when
a step stalls. See the Planner section of docs/actions.md.
"""

import difflib
import re
import time
import unicodedata

import decider
import planner as planning
import runlog as recording

ESCAPED = "Stopped — you pressed escape"
# A planned target picked below this asks the planner again. The narrow pick
# scored 0.95-0.99 when it was right.
PICK_FLOOR = 0.8
MAX_REPLANS = 3
UNCHANGED = "the last step changed nothing on screen — it did not work, try another way"
YES = "Yes, go ahead"
_PLAIN_YES = {"yes", "yeah", "yep", "yup", "sure", "ok", "okay", "go ahead", "yes go ahead",
              "do it", "oui"}
_PLAIN_NO = {"no", "nope", "nah", "no thanks", "dont", "do not", "cancel", "stop", "non"}
# One-line fields, where ⌘A selects only what the field holds.
ONE_LINE = {"AXTextField", "AXComboBox", "AXSearchField"}
OPENS_A_LIST = {"AXComboBox", "AXPopUpButton"}
COVER_HEIGHT = 60


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


class Outcome:
    def __init__(self, said, step=None, is_action=True, ends=False):
        self.said = said
        self.step = step if step is not None else said.lower()
        self.is_action = is_action
        self.ends = ends


def did(said, step=None, ends=False):
    return Outcome(said, step, True, ends)


def nothing(said):
    return Outcome(said, None, False)


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
    """Text fields by what they are called, and what is in them. Fields with
    the same name are told apart top to bottom, not by distance: the aim
    moves between reads."""
    by_name = {}
    for item in snapshot["items"]:
        if item["kind"] == "text":
            by_name.setdefault(item["name"] or item["role"].replace("AX", ""), []).append(item)
    fields = {}
    for called, items in by_name.items():
        items.sort(key=lambda i: (i["y"], i["x"]))
        for n, item in enumerate(items):
            fields[called if len(items) == 1 else f"{called} {n + 1}"] = item["value"]
    return fields


def changes(before, after):
    """What the last step did, as data. `window`: its new title. `appeared`:
    per part of the app that opened, its kind, the field it is near and its
    rows. `values`: fields whose text changed. `new`: other names that
    appeared. `gone`: how many names went."""
    change = {}
    if before["window"] != after["window"]:
        change["window"] = after["window"]
    was = {f"{i['kind']}\x01{i['name']}" for i in before["items"] if i["kind"] != "more"}
    new, counted, opened = [], set(), {}
    for item in after["items"]:
        if item["kind"] == "more":
            continue
        joined = f"{item['kind']}\x01{item['name']}"
        if joined in was or joined in counted:
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
    earlier, now = _fields(before), _fields(after)
    values = {name: value for name, value in now.items()
              if name in earlier and earlier[name] != value}
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
    gone_items = [i for i in before["items"] if i["kind"] != "more"
                  and f"{i['kind']}\x01{i['name']}" not in
                  {f"{a['kind']}\x01{a['name']}" for a in after["items"]}]
    renamed = _renamed(gone_items, [i for i in after["items"] if i["kind"] != "more"
                                    and f"{i['kind']}\x01{i['name']}" not in was])
    if renamed:
        change["renamed"] = renamed
        new = [n for n in new if n not in renamed.values()]
    gone = len(gone_items) - len(renamed)
    focus = _focused(after)
    if focus is not None and focus != _focused(before):
        change["focus"] = focus
    states = _states(before, after)
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


def _states(before, after):
    """Name to its states now, for items whose selected, expanded or checked
    changed. Focus is told apart."""
    def of(snapshot):
        return {(i["kind"], i["name"]): {s for s in i.get("state") or () if s != "focused"}
                for i in snapshot["items"] if i["name"]}
    was, now = of(before), of(after)
    return {key[1]: sorted(state) for key, state in now.items()
            if key in was and was[key] != state}


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
    for block in change.get("seen", ()):
        near = f" near \"{decider.prefix(block['near'], 30)}\"" if block.get("near") else ""
        lines = ", ".join(_seen_line(line) for line in block["lines"][:SEEN_SHOWN])
        out.append(f"text appeared{near} (seen, not in the tree): {lines}")
    if change.get("still"):
        lines = ", ".join(_still_line(line) for line in change["still"][:SEEN_SHOWN])
        out.append(f"still on screen, no longer in the tree (a panel may be hiding them): {lines}")
    return "; ".join(out)


def difference(before, after):
    """What the last step did, in a sentence; "" when nothing changed."""
    return sentence(changes(before, after))


# Slack's To: holds "\xa0 Alex Moreau \xa0 \xa0": one name per run of spaces.
_PARTS = re.compile(r"[,;\n ]|\s{2,}")
_LETTERS = re.compile(r"[^\W\d_]{2}")


def _inside(item, field):
    return abs(item["x"] - field["x"]) <= field["w"] / 2 \
        and abs(item["y"] - field["y"]) <= field["h"] / 2


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

    def texts(snapshot, box):
        return [box["value"]] + [i["name"] or i["value"] for i in snapshot["items"]
                                 if i is not box and i["kind"] != "text" and _inside(i, box)]
    kept = " ".join(_plain(t) for t in texts(after, now))
    out = []
    for text in texts(before, field):
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
        self.send = bool(settings.get("send", False))
        self.spotlight = float(settings.get("spotlight", 0))
        self.lookup_letters = int(settings.get("lookup_letters", 2))
        self.execute = request.get("execute", True)
        self.app = request.get("read_app")
        self.change = {}
        self.recorder = getattr(channel, "recorder", recording.OFF)
        self.agent = None

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
        self.recorder.update(kind="agent" if self.planner is not None and self.planner.loop == "agent"
                             else "plan" if self.planner is not None else "loop")
        try:
            if self.planner is not None and self.planner.loop == "agent":
                import agent
                self.agent = agent.Agent(self)
                self.agent.run(report)
            elif self.planner is not None:
                self._planned(report)
            else:
                self._run(report)
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

    def _run(self, report):
        if self.execute:
            self.call("watch")
        gaze = self.request.get("gaze")
        # Distances are measured from the gaze until something has happened,
        # then from wherever the work is now.
        aim = list(gaze) if gaze else [0, 0]
        previous = None
        quiet = 0
        last = ""
        repeats = 0
        # Shortcuts already taken. Offering one twice is how a run spends
        # itself pressing ⌘N.
        spent = []
        after_lookup = False
        # Chrome answers AXPress on a web element and does nothing: "click on
        # this image" pressed twice at two points and changed nothing.
        press_did_nothing = False
        pressed = False
        revealed = False
        steps = max(1, self.max_steps)

        for step in range(1, steps + 1):
            # The app this started in, every time. A misdirected ⌘N once put
            # the loop in a terminal and it carried on working there.
            named = previous["app"] if previous else self.app
            reply = self.call("snapshot", at=aim, app=named)
            if reply.get("error"):
                report.stopped = reply["error"]
                report.broke = True
                self.log(f"action loop: could not read the window at step {step} — {report.stopped}")
                return
            snapshot = reply["snapshot"]
            offers = decider.candidates(snapshot, self.utterance)
            self.log(f"action loop: step {step} reads {snapshot['app']} “{snapshot['window']}”"
                     f" — {len(snapshot['items'])} items, {len(offers)} offered")

            changed = difference(previous, snapshot) if previous is not None else None
            unchanged = changed == ""
            if unchanged:
                # Said out loud, the empty diff is the most useful sentence in
                # the state: the step was posted, reported, and moved nothing.
                changed = UNCHANGED
                if pressed:
                    press_did_nothing = True
                    self.log("action loop: the press did nothing; using the pointer next")
            if changed is not None:
                self.log(f"action loop: changed — {decider.prefix(changed, 160)}")
            if unchanged:
                quiet += 1
                if quiet >= 2:
                    report.stopped = "Nothing changed twice over — stopping"
                    self.log(f"action loop: {report.stopped}")
                    return
            else:
                quiet = 0

            if self.spotlight > 0 and self.execute:
                self.call("spotlight", snapshot=snapshot["id"], offers=[o["id"] for o in offers],
                          aim=aim, seconds=self.jev.timeout + 1)

            fresh = appeared(previous, snapshot) if revealed and previous else []
            if fresh:
                self.log(f"action loop: asking only about the {len(fresh)} new item(s)")

            self.show(now=True, activity="thinking…")
            try:
                decision = decider.decide(
                    self.jev, self.utterance, snapshot, done=report.steps, changed=changed,
                    # Without this, "open the Demo App conversation" answered
                    # click with no target and stopped: the row was below the fold.
                    can_scroll=step < steps, spent=spent,
                    notes=decider.notes_of(snapshot["app"], self.log), only=fresh,
                )
            except decider.Failure as failure:
                report.stopped = str(failure)
                report.broke = True
                self.log(f"action loop: the decider failed at step {step} — {report.stopped}")
                return
            print(f"jev decide {decision.ms} ms")
            self.log(f"action loop: step {step} · {decision.line} · finished "
                     f"{decision.finished:.2f} · {decision.ms} ms")

            if not self.execute:
                self.say(f"loop       step {step} · {decision.line} · {decision.ms} ms")
                if decision.target:
                    self.say(f"target     {decider.describe(decision.target, snapshot)}")
                if decision.text:
                    self.say(f"text       “{decision.text}”")
                self.say("(planned only)")
                report.stopped = "(planned only)"
                return

            # "open a new message to Antonio and Peter" pressed ⌘N five times:
            # every ⌘N redraws the window, so something always changed.
            target_name = decision.target["name"] if decision.target else ""
            signature = decision.action + (
                "" if decision.action in decider.IGNORES_TARGET else "\x01" + target_name)
            if signature == last and not press_did_nothing:
                repeats += 1
                if repeats >= 2:
                    report.stopped = "Asked for the same step three times — stopping"
                    self.log(f"action loop: repeated {decision.action} again; stopping")
                    return
                self.log(f"action loop: repeated {decision.action}; skipping it")
                previous = snapshot
                continue
            repeats = 0
            last = signature

            if decision.finished > 0.5:
                report.stopped = "Nothing to do" if not report.steps else "Done"
                self.log(f"action loop: {report.stopped} — finished {decision.finished:.2f}")
                return
            if decision.action == "none":
                report.stopped = "Nothing to do on screen" if not report.steps else "Done"
                self.log(f"action loop: {report.stopped} — nothing left to act on")
                return

            self.show(activity=f"{decision.action} “{decider.prefix(decision.target['name'], 40)}”…"
                      if decision.target and decision.target.get("name") else f"{decision.action}…")
            if self.spotlight > 0:
                chosen = decision.target["id"] if decision.target else None
                self.call("spotlight", snapshot=snapshot["id"], offers=[o["id"] for o in offers],
                          aim=aim, chosen=chosen, seconds=self.spotlight)
                time.sleep(self.spotlight)
                self.call("spotlight_dismiss")

            # After typing into a lookup field the next step picks from the
            # list it filtered, and that list only takes a real click.
            outcome = self.perform(decision, snapshot, aim, after_lookup or press_did_nothing)
            after_lookup = bool(decision.target and decision.target.get("lookup"))
            pressed = outcome.is_action and not (after_lookup or press_did_nothing)
            press_did_nothing = False
            revealed = decision.action in ("select", "show_menu")
            if not outcome.is_action:
                report.stopped = outcome.said
                self.log(f"action loop: stopped at step {step} — {outcome.said}")
                return
            report.acted = True
            # The caret is in an empty box words go into: the words are not
            # the loop's to supply.
            if not outcome.ends:
                box = self.call("ready_for_words", app=snapshot["app"]).get("box")
                if box:
                    report.steps.append(outcome.step)
                    report.shown.append(outcome.said)
                    report.stopped = f"{box} is ready — dictate"
                    self.log(f"action loop: the caret is in {box} and it is empty; your turn")
                    return
            if outcome.ends:
                report.steps.append(outcome.step)
                report.shown.append(outcome.said)
                report.stopped = "Waiting for the words"
                self.log("action loop: nothing left to do without the words")
                return
            if decision.action in decider.IGNORES_TARGET and decision.action not in spent:
                spent.append(decision.action)
            # The outcome, not the intention: "Opened a new message — say who
            # it is to" read to the model like an instruction still to carry out.
            report.steps.append(outcome.step)
            report.shown.append(outcome.said)
            previous = snapshot

            # A shortcut leaves the caret in what it opened; otherwise the
            # thing just acted on.
            focus = self.call("focus", app=snapshot["app"]).get("point")
            if focus:
                aim = focus
            elif decision.target:
                aim = decider.point(decision.target)
            self.log(f"action loop: measuring from {int(aim[0])},{int(aim[1])} now")
            time.sleep(0.5)

        report.stopped = f"Stopped after {self.max_steps} steps"
        self.log(f"action loop: {report.stopped}")

    # Following a plan

    def _planned(self, report):
        """The planner says what to do; Jev finds each target with a narrow
        question; the window says whether it worked. Re-planned when a step fails or opens
        something the plan does not use; stopped when a reason repeats."""
        if self.execute:
            self.call("watch")
        gaze = self.request.get("gaze")
        aim = list(gaze) if gaze else [0, 0]
        snapshot = self._read(aim, self.app)
        offers = decider.candidates(snapshot, self.utterance)
        notes = decider.notes_of(snapshot["app"], self.log)
        bundle = self.request.get("bundle", "")
        self.log(f"planner: reads {snapshot['app']} “{snapshot['window']}” — "
                 f"{len(snapshot['items'])} items, {len(offers)} sent to {self.planner.host}")
        self.show(now=True, activity="thinking…")
        plan = self.planner.plan(planning.context(self.utterance, snapshot, offers, bundle, notes))
        self._log_plan("planned", plan)

        if not self.execute:
            self.say(f"plan       {len(plan.steps)} steps · {plan.ms} ms")
            for line in plan.lines():
                self.say(f"           {line}")
            if plan.unsure:
                self.say(f"unsure     {plan.unsure}")
            first = plan.steps[0] if plan.steps else None
            if first and first["target"] and first["do"] != "key":
                try:
                    item, why = self._find(first, snapshot)
                    if item is not None and item.get("refused"):
                        item, why = None, f"{decider.short(item, snapshot)} is on never_press"
                    self.say(f"target     “{first['target']}” → "
                             + (decider.short(item, snapshot) if item else f"✗ {why}"))
                except Stop as stop:
                    self.say(f"target     ✗ {stop.text}")
            self.say("(planned only)")
            report.stopped = "(planned only)"
            return
        if not plan.steps:
            report.stopped = f"No plan: {plan.unsure}" if plan.unsure else "Nothing to do"
            return

        steps = list(plan.steps)
        self.change = {}
        self.fresh = set()
        self.renamed = {}
        taken = []        # (step, what came of it), for the advice call
        counts = {}
        quiet = 0
        replans, whys = 0, set()
        index = 0
        done = 0
        while index < len(steps):
            if done >= max(1, self.max_steps):
                report.stopped = f"Stopped after {self.max_steps} steps"
                self.log(f"planner: {report.stopped}")
                return
            step = steps[index]
            done += 1
            self.log(f"planner: step {done} · {planning.describe_step(step)}")
            why, snapshot, aim, outcome = self._planned_step(step, snapshot, aim, report)
            if why is None:
                taken.append((step, outcome))
                signature = (step["do"], step["target"].lower(), step["value"])
                counts[signature] = counts.get(signature, 0) + 1
                unchanged = outcome.endswith(UNCHANGED)
                quiet = quiet + 1 if unchanged and step["do"] not in ("type", "write") else 0
                if counts[signature] >= 3:
                    why = "the same step three times"
                elif quiet >= 2:
                    why = "nothing changed twice"
                elif step["expect"] and not (step["do"] == "click" and self.target_kind == "text"):
                    # Teams: "Message compose box focused" scored 0.47 with the
                    # caret in it. Focus is not in the read.
                    seen = decider.visible(self.jev, step["expect"], snapshot, outcome)
                    self.log(f"planner: expected “{step['expect']}” — {seen:.2f}")
                    if seen < 0.5:
                        why = f"expected “{step['expect']}” and it is not on screen ({seen:.2f})"
                if why is None:
                    why = self._surprise(step, steps[index + 1] if index + 1 < len(steps) else None)
            else:
                taken.append((step, f"failed: {why}"))
            if why is None:
                index += 1
                continue
            if replans >= MAX_REPLANS or why in whys:
                report.stopped = f"Stopped at “{self._short(step)}” — {why}"
                self.log(f"planner: {report.stopped}; "
                         + ("the same way twice" if why in whys else f"asked {replans} times already"))
                return
            replans += 1
            whys.add(why)
            self.log(f"planner: asking again — {why}")
            offers = decider.candidates(snapshot, self.utterance)
            screen = planning.context(self.utterance, snapshot, offers, bundle, notes,
                                      change=self.change)
            self.show(now=True, activity="thinking…")
            advice = self.planner.advise(screen, taken, why)
            self._log_plan("re-planned", advice)
            if not advice.steps:
                report.stopped = f"Stopped at “{self._short(step)}” — {why}"
                return
            steps, index, quiet = list(advice.steps), 0, 0

        box = self.call("ready_for_words", app=snapshot["app"]).get("box")
        report.stopped = f"{box} is ready — dictate" if box else "Done"
        self.log(f"planner: {report.stopped}")

    def _surprise(self, step, following):
        """A part that opened and that the plan does not use, or None. Asked of
        the read, not of a model: an expect check passed at 0.96 on a typed
        name while Outlook's suggestion row went unpicked."""
        for part in self.change.get("appeared", ()):
            # "To" matched Outlook's row "To change selection, press Control-Option".
            target = {w for w in decider._words(following["target"]) if len(w) > 2} \
                if following else set()
            if target and any(target <= set(decider._words(row)) for row in part["rows"]):
                continue
            if following is None and step["do"] not in ("type", "write"):
                continue
            rows = ", ".join(f"“{decider.prefix(r, 40)}”" for r in part["rows"][:4])
            near = f" near “{part['near']}”" if part.get("near") else ""
            nxt = f"the next step, “{self._short(following)}”, does not use it" if following \
                else "the plan ends with it open"
            return f"a {part['kind']} opened{near} with {rows}, and {nxt}"
        for block in self.change.get("seen", ()):
            target = {w for w in decider._words(following["target"]) if len(w) > 2} \
                if following else set()
            if target and any(target <= set(decider._words(line["text"])) for line in block["lines"]):
                continue
            if following is None and step["do"] not in ("type", "write"):
                continue
            lines = ", ".join(f"“{decider.prefix(line['text'], 40)}”" for line in block["lines"][:4])
            near = f" near “{block['near']}”" if block.get("near") else ""
            nxt = f"the next step, “{self._short(following)}”, does not use it" if following \
                else "the plan ends with it open"
            return f"text appeared{near} (seen, not in the tree): {lines}, and {nxt}"
        return None

    def _log_plan(self, how, plan):
        self.log(f"planner: {how} {len(plan.steps)} steps in {plan.ms} ms, {plan.tokens} tokens in")
        for line in plan.lines():
            self.log(f"planner:   {line}")
        if plan.unsure:
            self.log(f"planner:   unsure — {decider.prefix(plan.unsure, 200)}")

    @staticmethod
    def _short(step):
        return f"{step['do']} {step['target'] or step['value']}".strip()

    def _read(self, aim, app):
        """The window, with `seen`, its text read from the pixels, when the
        app read it."""
        reply = self.call("snapshot", at=aim, app=app, see=True)
        if reply.get("error"):
            raise Stop(reply["error"], broke=True)
        snapshot = reply["snapshot"]
        if isinstance(reply.get("seen"), list):
            snapshot["seen"] = reply["seen"]
        # Its picture, for `ground`: {file, frame, scale, w, h}.
        if isinstance(reply.get("shot"), dict) and reply["shot"].get("file"):
            snapshot["shot"] = reply["shot"]
        return snapshot

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

    def _typed(self):
        where = self.__dict__.pop("typing", None)
        if where is not None:
            self.__dict__.setdefault("typed", set()).add(where)

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
        if reply.get("error") == "covered":
            self.log(f"planner: not clicked — {reply.get('text')}")
            return reply.get("text") or "the target is covered"
        if reply.get("error") and reply.get("said"):
            raise Stop(reply.get("text") or reply["error"])
        if reply.get("error"):
            return reply["error"]
        return None

    def _caret_in(self, target, snapshot):
        """Whether the caret is already in `target`: then typing needs no click."""
        if "focused" in (target.get("state") or ()):
            return True
        point = self.call("focus", app=snapshot["app"]).get("point")
        if not point:
            return False
        x, y = point
        return abs(x - target["x"]) <= target["w"] / 2 + 2 and abs(y - target["y"]) <= target["h"] / 2 + 2

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
        target = None
        closed = ""
        self.target_kind = None
        if do == "type":
            unsaid = [w for w in decider._words(value)
                      if len(w) > 2 and w not in decider._words(self.utterance)
                      and not decider.words_seen(w, snapshot)]
            answer = unsaid and self._allowed(
                f"Type “{decider.prefix(value, 40)}”? You did not say {', '.join(unsaid[:4])}",
                frame(item))
            if unsaid and answer != YES:
                return (self._refused(answer, "would type words that were not said: "
                                      + ", ".join(unsaid[:4])), snapshot, aim, "")
        if do in ("type", "write") and value:
            typed = self.__dict__.setdefault("typed", set())
            where = (item["name"] if item else step.get("target", ""), value)
            if where in typed:
                answer = self._allowed(f"Type “{decider.prefix(value, 40)}” there again?",
                                       frame(item))
                if answer != YES:
                    return (self._refused(answer, f"“{decider.prefix(value, 40)}” was already "
                                          "typed there; its list may be open: pick from it or "
                                          "read the screen"), snapshot, aim, "")
            # Counted once typed. Seen 09-23: a click refused as covered
            # typed nothing, and the retry was asked about as a repeat.
            self.typing = where
        if do == "key" and value == "cmd+a":
            role = self.call("focus", app=snapshot["app"]).get("role")
            if role in ONE_LINE:
                self.log(f"planner: ⌘A in a one-line field ({role}), not asked")
            else:
                answer = self._allowed("Select all?")
                if answer != YES:
                    return (self._refused(answer, "select all would put existing text at risk"),
                            snapshot, aim, "")
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
            spot = decider.point(target) if target else aim
            self.act("scroll", x=spot[0], y=spot[1], down=value.lower() != "up", turns=6)
        elif do in ("type", "write") and item is None \
                and step["target"].lower() in ("", "no name"):
            if not value:
                return "nothing to type", snapshot, aim, ""
            self.front()
            self.act("paste" if do == "write" else "type", text=value)
            self._typed()
        else:
            target, why = (item, None) if item is not None else self._find(step, snapshot)
            if target is None:
                return why, snapshot, aim, ""
            self.target_kind = target["kind"]
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
            if target["kind"] == "seen":
                self.front()
                why = self._click_at(target)
            elif do in ("type", "write") and self._caret_in(target, snapshot):
                # Seen 09-23 in Slack: clicking To's centre selected the first
                # recipient's chip, and typing the second name replaced it.
                why = None
            else:
                why = self._press(target, click=bool(target.get("in_list") or target.get("in")
                                                     or fresh or target["role"] == "AXStaticText"))
            if why:
                return why, snapshot, aim, ""
            if do in ("type", "write"):
                if not value:
                    return "nothing to type", snapshot, aim, ""
                time.sleep(0.3)
                self.front()
                # Key presses for `type`, the paste for `write`. Seen 09-23 in
                # Outlook: the time field's hour ignored a pasted "11" three times.
                self.act("type" if do == "type" else "paste", text=value)
                self._typed()
        report.acted = True
        time.sleep(0.5)
        now = self._read(aim, snapshot["app"])
        change = changes(snapshot, now)
        # Teams' attendee list came after the read: "nothing changed", and
        # the name was typed again. Lookups wait before they filter.
        for _ in range(3 if do in ("type", "write") and not change else 0):
            time.sleep(0.4)
            now = self._read(aim, snapshot["app"])
            change = changes(snapshot, now)
            if change:
                break
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
            time.sleep(0.5)
            now = self._read(aim, snapshot["app"])
            change = changes(snapshot, now)
            changed = sentence(change)
        self.change = change
        outcome = changed or UNCHANGED
        if closed:
            outcome = f"{closed}; {outcome}"
        self.log(f"planner: changed — {decider.prefix(outcome, 160)}")
        said = planning.describe_step(dict(step, expect=""))
        report.steps.append(f"{said}; {decider.prefix(outcome, 120)}")
        report.shown.append(self._shown(step))
        focus = self.call("focus", app=now["app"]).get("point")
        if focus:
            aim = focus
        elif target is not None:
            aim = decider.point(target)
        return None, now, aim, outcome

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

    @staticmethod
    def _shown(step):
        do, target, value = step["do"], step["target"], step["value"]
        if do == "key":
            return f"Pressed {value}"
        if do == "scroll":
            return f"Scrolled {value or 'down'}"
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
        if reply.get("error") == "covered":
            raise Stop(reply.get("text") or "the target is covered")
        if reply.get("error"):
            raise Stop(reply.get("text") or reply["error"], broke=True)
        return reply

    def front(self):
        """A chord goes to whatever is frontmost. ⌘N for a Slack message once
        opened a terminal window instead."""
        self.act("front")

    def perform(self, decision, snapshot, aim, click_rather_than_press):
        target = decision.target
        # never_press, before anything is posted. The app refuses it again at
        # the moment of acting.
        if target and target.get("refused"):
            self.log(f"action: refused — \"{decider.prefix(target['name'], 40)}\" matches "
                     f"\"{target['refused']}\"")
            return nothing(f"Won't press \"{decider.prefix(target['name'], 30)}\" — that is yours to do")
        action = decision.action

        if action == "none":
            return nothing("Nothing to do on screen")

        if action == "scroll":
            # Which way is in the words. Where is the gaze: an arrow key
            # scrolled the conversation when the sidebar was asked for.
            words = self.utterance.lower()
            down = "down" in words or "bas" in words or "descend" in words
            spot = decider.point(target) if target else aim
            self.act("scroll", x=spot[0], y=spot[1], down=down, turns=6)
            return did("Scrolled down where you were looking" if down
                       else "Scrolled up where you were looking")

        if action == "new_message":
            # The picker is opened by a shortcut: a target not on screen can
            # never be offered.
            self.front()
            self.act("key", keys="cmd+n")
            return did("Opened a new message — say who it is to",
                       step="opened a new message; its recipient field is now on screen")

        if action == "search":
            # Slack's search bar is not a text field to the accessibility API,
            # so it is never offered: the model chose the composer at 0.80.
            # ⌘G is Slack's own shortcut, and wrong in another app.
            self.front()
            self.act("key", keys="cmd+g", wait=400)
            if not decision.text:
                return did("Opened search")
            self.act("paste", text=decision.text)
            if self.send:
                self.act("key", keys="return")
            return did(f"Searched for {decision.text}")

        if action == "show_menu":
            # A web image with no alt text has no name and no item: where you
            # looked is the answer a right-click always wanted.
            spot = decider.point(target) if target else aim
            name = decider.label(target) if target else "what you were looking at"
            self.front()
            if target:
                self.act("show_menu", id=target["id"])
            else:
                self.act("show_menu", x=spot[0], y=spot[1])
            time.sleep(0.4)
            return did(f"Opened the menu on {name}",
                       step=f"opened the menu on \"{name}\"; its choices are on screen now")

        if action == "select":
            if not target:
                return nothing("Nothing here to select")
            name = decider.label(target)
            self.front()
            self.act("select", id=target["id"])
            time.sleep(0.3)
            return did(f"Selected {name}", step=f"selected the text of \"{name}\"; it is highlighted now")

        # click, type, send_message
        if not target:
            return nothing(f"Nothing here matches \"{self.utterance}\"")
        self.act("press", id=target["id"], click=click_rather_than_press)
        name = decider.label(target)
        # Picking from an open list is the whole step. Running on added Peter
        # and went straight to the message box with Samir still to add.
        if action == "click" or target.get("in_list"):
            return did(f"Picked {name}",
                       step=f"picked \"{name}\" from the list; that is one recipient in")
        time.sleep(0.5)

        # The message goes in the composer, and the thing clicked was the
        # conversation. Found again: the window has changed.
        if action == "send_message" and target["kind"] != "text":
            time.sleep(0.6)
            composer = self.composer(snapshot["app"])
            if composer is None:
                return nothing(f"Opened {name}, but found no message box")
            self.act("press", id=composer["id"], click=False)
            time.sleep(0.3)

        # A name only goes into a field that looks names up: the model once
        # picked the composer and "Peter", and "Pe" was typed as the message.
        # First letters only; see lookup_letters.
        looked = None
        if target.get("lookup") and decision.word:
            looked = (decision.word[:self.lookup_letters] if self.lookup_letters > 0
                      else decision.word)
        text = decision.text or looked
        if not text:
            if target.get("lookup"):
                return did("Put the caret in the lookup field — no name to type",
                           step="put the caret in the lookup field; no name was picked to type")
            return did(f"{name} is ready — dictate the message",
                       step=f"put the caret in \"{name}\"; there were no words to type", ends=True)
        # Pasting "Pe" into Slack's recipient field made a token, not a list:
        # a lookup field gets keystrokes.
        if target.get("lookup"):
            self.act("type", text=text)
            what = f"typed \"{text}\" into the lookup field; the list below it has narrowed"
        else:
            self.act("paste", text=text)
            what = f"typed \"{text}\" into \"{name}\""
        if not self.send:
            return did(f"Typed “{text}” into {name}", step=what)
        self.act("key", keys="return")
        return did(f"Sent to {name}", step=what + " and pressed Return")

    def composer(self, app):
        """The message box: a text field in the bottom fifth of the window.
        It has no name in Slack, so where it is is all there is."""
        reply = self.call("snapshot", at=[0, 0], app=app)
        if reply.get("error"):
            return None
        now = reply["snapshot"]
        return next((i for i in now["items"]
                     if i["kind"] == "text" and decider.relative_y(now, i) > 0.8), None)


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
