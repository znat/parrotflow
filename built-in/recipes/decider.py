"""One wide question to Jev: which action, on which target.

The model selects, code executes, the gaze breaks ties. The model picks one
of the actions and one of the targets it was offered. It never writes text:
the words to type are cut out of the utterance by `message_text`.

Measured on 2026-09-20 with this wording and this key order: named targets
8/8 in English and French, 620-750 ms per call, ~3.3k input tokens. Key order
is part of what was measured, so the request is built in a fixed order.

A snapshot is what the app's `snapshot` step returns. Each item carries the
app's own verdicts: `lookup` (a field that narrows a list), `in_list` (a row
of an open list), `clickable`, `refused` (the never_press word it matches,
or null), and `in` (the part of the app that opened during the run and holds
it: "pop-up", "menu", "dialog", "sheet", "window"; null for the window). An
item of kind `more` stands for the children of a wide element left unread.
"""

import json
import os
import re
import time
import unicodedata

from judge import Chance, Failure, Pick  # noqa: F401

# `ignores_target` actions do the same thing whatever target was picked.
ACTIONS = [
    ("click", "activate one on-screen target: press a button, open a conversation, follow a "
              "link, pick an item"),
    ("type", "put words into a text field without sending them"),
    ("send_message", "write a message and send it, in a conversation or to a person that is on "
                     "the screen"),
    ("new_message", "start a new message, when the person or people to write to are not on the "
                    "screen to pick"),
    ("search", "look something up with the search field"),
    ("scroll", "move the view up or down"),
    # AXShowMenu is on every one of 224 items in a real Slack window.
    ("show_menu", "open the menu of choices on one target — what a right-click, a secondary "
                  "click or “more actions” gives you"),
    ("select", "select the text of one target, so that something can then be done with it — "
               "highlight it, mark it, pick it out"),
    ("none", "the utterance is not a request to act on this screen"),
]
NAMES = [name for name, _ in ACTIONS]
IGNORES_TARGET = {"new_message", "search", "scroll", "none"}

# 40 fit in a call of 3.3k tokens. The name match reached John's button at
# 7.5 cm over his message at 5.1 cm, and "click on Antonio" a row 12 cm away.
OFFERED = 40


# Text, the way Swift counts it


_EXTEND = {0x200D, 0xFE0E, 0xFE0F}


def _extends(ch):
    code = ord(ch)
    return (unicodedata.category(ch) in ("Mn", "Mc", "Me") or code in _EXTEND
            or 0x1F3FB <= code <= 0x1F3FF or 0xE0020 <= code <= 0xE007F
            or 0xFE00 <= code <= 0xFE0F or 0xE0100 <= code <= 0xE01EF)


def _is_ri(ch):
    return 0x1F1E6 <= ord(ch) <= 0x1F1FF


def graphemes(text):
    """Close enough to Swift's Characters for names: combining marks, emoji
    modifiers, ZWJ sequences, flags and CRLF stay together."""
    clusters = []
    for ch in text:
        if clusters:
            last = clusters[-1]
            joins = (_extends(ch) or last[-1] == "‍"
                     or (last == "\r" and ch == "\n")
                     or (_is_ri(ch) and _is_ri(last[-1])
                         and sum(1 for c in last if _is_ri(c)) % 2 == 1))
            if joins:
                clusters[-1] = last + ch
                continue
        clusters.append(ch)
    return clusters


def prefix(text, count):
    return "".join(graphemes(text)[:count])


def length(text):
    return len(graphemes(text))


def _trim_spaces(text):
    """`.whitespaces`: spaces and tabs, not newlines."""
    def space(ch):
        return ch == "\t" or unicodedata.category(ch) == "Zs"
    start, end = 0, len(text)
    while start < end and space(text[start]):
        start += 1
    while end > start and space(text[end - 1]):
        end -= 1
    return text[start:end]


def _alnum(ch):
    return unicodedata.category(ch)[0] in "LMN"


def _trim_non_alnum(word):
    start, end = 0, len(word)
    while start < end and not _alnum(word[start]):
        start += 1
    while end > start and not _alnum(word[end - 1]):
        end -= 1
    return word[start:end]


def _words(text):
    return re.findall("[a-zà-ÿ]+", text.lower())


def _quoted(text):
    return json.dumps(text, ensure_ascii=False)


# Items


def key(item):
    """Swift's `Item ==`: every field it has, none of the ones the app adds."""
    return (item["kind"], item["role"], item["name"], item["value"], float(item["cm"]),
            item["x"], item["y"], item["w"], item["h"], tuple(item.get("actions") or ()),
            item.get("in"), tuple(item.get("state") or ()))


def relative_y(snapshot, item):
    frame = snapshot["frame"]
    return (item["y"] - frame["y"]) / max(frame["h"], 1)


def point(item):
    return [item["x"], item["y"]]


def label(item):
    """What a step calls a target: its name, or its role when it has none."""
    return item["role"] if not item["name"] else prefix(item["name"], 40)


def candidates(snapshot, utterance):
    """The 40 nearest, then anything further whose name shares a word of three
    letters or more with the utterance, then every text field, then whatever
    is in a part of the app that opened during the run."""
    spoken = {w for w in _words(utterance) if len(w) > 2}
    # A timestamp, a read receipt, a line of a message: near and useless.
    # After one recipient was added, Slack's preview put twenty of them in
    # the list and the next step picked one at 0.41.
    worth = [item for item in snapshot["items"] if item["kind"] not in ("label", "more")]
    picked = worth[:OFFERED]
    for item in worth[OFFERED:]:
        if spoken & set(_words(item["name"])):
            picked.append(item)
    # Slack's recipient field sat 12.8 cm from the gaze, 87th of 127, and
    # has no name: only this rule ever offered it.
    seen = {key(item) for item in picked}
    for item in snapshot["items"]:
        if item["kind"] == "text" and key(item) not in seen:
            picked.append(item)
            seen.add(key(item))
    # Outlook's suggestion list is outside the compose window; its rows can
    # be far from the gaze and still be the next step.
    for item in worth:
        if item.get("in") and key(item) not in seen:
            picked.append(item)
            seen.add(key(item))
    return picked


def describe(item, snapshot):
    """Role, name, distance, and where in the window it sits."""
    role = item["role"].replace("AX", "")
    name = item["name"] if item["name"] else _trim_spaces(item["value"])
    if item["kind"] == "text" and not name:
        # The role first: a combo box looks things up. Calling it "the search
        # field", as its position did, is why names were never typed into it.
        down = relative_y(snapshot, item)
        if item["role"] == "AXComboBox":
            name = ("a field that looks people and channels up as you type "
                    "(type a name into it, then pick from the list that appears)")
        elif down > 0.8:
            name = "message composer (empty text area at the bottom)"
        elif down < 0.15:
            name = "search field (top)"
        else:
            name = "empty text field"
    where = whereabouts(item, snapshot)
    state = ", ".join(item.get("state") or [])
    return (f"{role} “{prefix(name, 70)}”, {float(item['cm'])!r} cm from the gaze"
            + (f", {state}" if state else "") + (f", {where}" if where else ""))


def whereabouts(item, snapshot):
    """Sidebar, or the list under a lookup field. Told apart by nothing, the
    same person in both places was picked at 0.40, always the sidebar."""
    if item.get("in"):
        return f"in the {item['in']} that opened during this request"
    field = next((i for i in snapshot["items"] if i.get("lookup")), None)
    if field is not None and key(item) != key(field):
        # Slack's picker: field at x=956, rows at 963, a profile card at 1290,
        # the sidebar at 501. 120 separates the list from the rest.
        below = field["y"] < item["y"] < field["y"] + 520
        if below and abs(item["x"] - field["x"]) < 120:
            return "in the list under the recipient field — clicking it adds that person"
    frame = snapshot["frame"]
    if item["x"] - frame["x"] < frame["w"] * 0.28:
        return "in the sidebar — clicking it leaves this screen and opens that conversation"
    return None


def names_in(utterance):
    """Capitalised words of three letters or more, minus the first word,
    which the decoder capitalises whatever it is. The options a lookup field
    can be given: nothing is typed that was not said."""
    words = [w for w in (_trim_non_alnum(w) for w in utterance.split()) if w]
    found = []
    for index, word in enumerate(words):
        if index == 0 or length(word) <= 2 or not word[0].isupper():
            continue
        if word not in found:
            found.append(word)
    return found[:8]


_QUOTED = re.compile("[\"“](.+?)[\"”]")
_AFTER = re.compile(r"\b(?:saying|that says|that|say|tell (?:him|her|them)|disant|:)\s+(.+)$",
                    re.IGNORECASE)


def message_text(utterance):
    """The words to type, out of the utterance itself. The model never writes
    them: a message it composed is a message nobody said."""
    found = _QUOTED.search(utterance)
    if found:
        return found.group(1).strip()
    found = _AFTER.search(utterance)
    if found:
        return found.group(1).strip()
    return None


# App notes


_notes = {}
_NEWLINES = re.compile("\r\n|[\n\r\x0b\x0c\x85  ]")


def slug(app):
    parts, run = [], ""
    for ch in app.lower():
        if _alnum(ch):
            run += ch
        elif run:
            parts.append(run)
            run = ""
    if run:
        parts.append(run)
    return "-".join(parts)


def twin_rank(item):
    """Which of two same-named items wins: the focused one, then one in the
    focused window, then the first in reading order. Seen 09-24: two Outlook
    event forms, and the first in reading order was behind."""
    return ("focused" not in (item.get("state") or ()), item.get("in") == "window",
            item["y"], item["x"])


def notes_of(app, log):
    """`<config>/apps/<app>.md`, headings and comment lines dropped. Read again
    when the file changes. Not capped: a page of rules is ~350 tokens against
    the 3.3-3.7k the targets cost."""
    name = slug(app)
    folder = os.environ.get("PARROTFLOW_APP_NOTES", "")
    if not name or not folder:
        return None
    path = os.path.join(folder, name + ".md")
    try:
        written = os.stat(path).st_mtime
    except OSError:
        written = None
    cached = _notes.get(name)
    if cached and cached[1] == written:
        return cached[0] or None
    text = ""
    if written is not None:
        try:
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
        except (OSError, UnicodeDecodeError):
            text = ""
    lines = (_trim_spaces(line) for line in _NEWLINES.split(text))
    useful = " ".join(line for line in lines
                      if line and not line.startswith("#") and not line.startswith("<!--"))
    if useful and (cached is None or cached[0] != useful):
        count = length(useful)
        log(f"actions: read the house rules for {app} — {count} characters,"
            f" about {count // 4} tokens on every step")
    _notes[name] = (useful, written)
    return useful or None


# The call


def request(utterance, snapshot, offers, done=(), changed=None, can_scroll=False, spent=(),
            notes=None):
    """(state, questions) for the one wide question."""
    note = ("The user looks at a point on the screen and speaks. Each target gives its "
            "distance from that point in cm; nearer targets are more likely to be meant, but a "
            "name in the utterance beats distance.")
    # Only when another step can follow: the single-step request stays word
    # for word the one the twelve cases were measured against.
    if can_scroll:
        note += (" Only what is drawn on screen is listed. Something the user named may exist "
                 "further down the list and not be here at all — scrolling brings more into view, "
                 "and it is a step worth taking when nothing listed matches.")
    targets = {f"t{i}": describe(item, snapshot) for i, item in enumerate(offers)}
    state = {
        "utterance": utterance,
        "app": snapshot["app"],
        "window": snapshot["window"],
        "note": note,
    }
    if done:
        state["done"] = list(done)
        if changed is not None:
            state["changed"] = changed
        state["next"] = ("The steps in `done` have already happened. Answer with the next step "
                         "only, and answer `none` when the utterance has been carried out in full.")
    if notes:
        state["how_this_app_works"] = notes
    state["targets"] = targets

    # Measured: with both recipients in `done` it still answered "Peter" at
    # 0.40 until `none` also meant "already carried out". A shortcut already
    # taken is not offered again: it answered `new_message` four times in a row.
    actions = {}
    for name, said in ACTIONS:
        if name in spent:
            continue
        if name == "none" and done:
            said += ", or the steps in `done` have already carried it out in full"
        actions[name] = said
    target_choices = dict(targets)
    target_choices["none"] = "no listed target fits the utterance"
    questions = {
        "action": Pick("What does the user ask to do on this screen?", actions),
        "target": Pick("Which target in `targets` does the utterance act on? For a message to a "
                       "person, that is the person or their conversation; for typing, the text "
                       "field.", target_choices),
        "has_text": Chance("Does the utterance contain the words to type or send, not only the "
                           "request to type or send something?"),
        "deictic": Chance("Does the utterance point at what the user is looking at (\"this\", "
                          "\"here\", \"that one\", \"ça\", \"ici\") rather than naming it?"),
    }
    names = names_in(utterance)
    if can_scroll and names:
        criteria = {f"w{i}": name for i, name in enumerate(names)}
        criteria["none"] = "this step does not put a name into a field"
        questions["word"] = Pick(
            "Only for a step whose target is a field that looks people and channels up as you "
            "type. Which name from the utterance goes into it now? Pick one that `done` does not "
            "already show as entered. Answer none for every other step, including writing the "
            "message itself — a name typed into a message box is not a recipient, it is the "
            "message.", criteria)
    if done:
        questions["finished"] = Chance(
            "Have the steps in `done` already carried out the user's request in full, so that "
            "nothing further needs doing on this screen?")
    return state, questions


class Decision(dict):
    def __getattr__(self, name):
        try:
            return self[name]
        except KeyError:
            raise AttributeError(name)

    @property
    def line(self):
        said = f"{self.action} {self.action_p:.2f}"
        said += f" · target {self.target_id} {self.target_p:.2f}"
        if self.by_gaze:
            said += f" (gaze, over {self.model_target_id})"
        said += f" · text {self.has_text:.2f}"
        said += f" · deictic {self.deictic:.2f}"
        return said


def read(answers, offers, utterance, ms):
    def noul(name):
        return answers[name].value if name in answers else 0.0

    action, action_p = answers["action"].value, answers["action"].p
    if action not in NAMES:
        action = "none"
    target_id, target_p = answers["target"].value, answers["target"].p
    target = None
    if target_id != "none" and target_id[1:].isdigit() and int(target_id[1:]) < len(offers):
        target = offers[int(target_id[1:])]
    deictic = noul("deictic")
    has_text = noul("has_text")
    word = None
    if "word" in answers:
        chosen = answers["word"].value
        names = names_in(utterance)
        if chosen != "none" and chosen[1:].isdigit() and int(chosen[1:]) < len(names):
            word = names[int(chosen[1:])]

    # The model cannot decide a deictic: over the three nearest it came back
    # 0.27 / 0.24 / 0.20. Then the gaze decides, but only when the model's
    # own target cannot take the action: overriding every deictic cost two of
    # the twelve measured cases ("reply here: on it, thanks" named the
    # composer at 0.80 and was dragged onto a group 0.7 cm nearer).
    by_gaze = False
    chosen_id = target_id
    if deictic > 0.5 and action != "none" and (target is None or not target.get("clickable")):
        nearest = next((o for o in offers if o.get("clickable")), None)
        if nearest is not None:
            target = nearest
            wanted = key(nearest)
            chosen_id = next(f"t{i}" for i, o in enumerate(offers) if key(o) == wanted)
            by_gaze = True

    return Decision(
        action=action, target=target, target_id=chosen_id, model_target_id=target_id,
        action_p=action_p, target_p=target_p, has_text=has_text, deictic=deictic,
        text=message_text(utterance) if has_text > 0.5 else None, word=word,
        by_gaze=by_gaze, finished=noul("finished"), ms=ms,
        input_tokens=answers.input_tokens,
    )


def decide(jev, utterance, snapshot, done=(), changed=None, can_scroll=False, spent=(),
           notes=None, only=()):
    """One call. `only`: what the last step drew. After a selection in Notion,
    "add a comment" over 163 targets picked a colour button at 0.31; the
    toolbar that had just appeared was a handful of items."""
    if only:
        shown = {key(item) for item in only}
        offers = list(only) + [item for item in snapshot["items"]
                               if item["kind"] == "text" and key(item) not in shown]
    else:
        offers = candidates(snapshot, utterance)
    state, questions = request(utterance, snapshot, offers, done, changed, can_scroll, spent, notes)
    started = time.monotonic()
    answers = jev.ask(state, questions)
    ms = int((time.monotonic() - started) * 1000)
    return read(answers, offers, utterance, ms)


# Narrow questions, for a planned step


def short(item, snapshot):
    """Role and name, for a pick among a few. An unnamed field gets the
    placeholder `describe` gives it."""
    name = item["name"] or _trim_spaces(item["value"])
    if not name:
        return describe(item, snapshot).split(", ")[0]
    return f"{item['role'].replace('AX', '')} “{prefix(' '.join(name.split()), 90)}”"


def pick(jev, question, among, snapshot, utterance):
    """Which of `among` answers `question`. (item or None, p, ms)."""
    criteria = {"none": "none of these is it"}
    for i, item in enumerate(among):
        criteria[f"r{i}"] = short(item, snapshot)
    started = time.monotonic()
    answer = jev.ask({"utterance": utterance, "app": snapshot["app"],
                      "window": snapshot["window"], "question": question},
                     {"pick": Pick(question, criteria)})["pick"]
    ms = int((time.monotonic() - started) * 1000)
    chosen, probabilities, p = answer.value, answer.probabilities, answer.p
    if chosen != "none" and chosen[1:].isdigit() and int(chosen[1:]) < len(among):
        item = among[int(chosen[1:])]
        # Teams draws "Create a new event." twice; Jev split its answer
        # between the two and neither passed the floor. Same name, same kind:
        # one choice, and the first in reading order.
        twins = [i for i, other in enumerate(among)
                 if other["kind"] == item["kind"] and _words(other["name"]) == _words(item["name"])]
        if len(twins) > 1:
            p = sum(float(probabilities.get(f"r{i}", 0)) for i in twins) or p
            item = min((among[i] for i in twins), key=lambda o: (o["y"], o["x"]))
        return item, p, ms
    return None, p, ms


def words_seen(words, snapshot):
    """Whether any word of `words` is in the name or text of anything read."""
    wanted = {w for w in _words(words) if len(w) > 2}
    if not wanted:
        return True
    for item in snapshot["items"]:
        if wanted & set(_words(item["name"] + " " + item["value"])):
            return True
    return False
