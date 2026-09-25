"""What a recipe gets. The recipe asks, ParrotFlow acts.

A recipe is a function declared with `@recipe`. A file can hold several.

    from parrotflow import recipe

    @recipe(app="com.microsoft.Outlook", says="write an email to one or more people",
            needs=["who"])
    def message_people(app, ask):
        app.key("cmd+n", wait=1200)
        ...

- `app` is the app's name as macOS shows it ("Microsoft Outlook") or its
  bundle ID ("com.microsoft.Outlook"). The bundle ID does not change with the
  system language. Find it with `osascript -e 'id of app "Microsoft Outlook"'`.
- `says` is what the recipe does. Jev picks the recipe whose `says` fits what
  was said, by meaning, not word for word.
- `needs` is "who", "what" or both: what Jev reads out of the sentence.
- `allows` takes words off `never_press` for this recipe's clicks.
- `name` defaults to the function's name. A recipe in the user's folder with
  the same name and app replaces the built-in one.

`runner.py` imports the files, picks a recipe and calls it. Each `app` call is
one step: one JSON line to the app and one line back. The app does the
reading, typing and clicking, so its checks apply to every step: Escape ends
the run, and a click on anything in `never_press` is refused unless the
recipe allows it.

`print()` goes to the ParrotFlow log, not to the app.
"""

# Filled by @recipe while runner.py imports a file.
declared = []


def recipe(app, says, needs=(), allows=(), name=None):
    unknown = set(needs) - {"who", "what"}
    if unknown:
        raise ValueError(f"needs can only be who or what, not {', '.join(sorted(unknown))}")

    def register(fn):
        fn.recipe = {"name": name or fn.__name__, "app": app, "says": says,
                     "needs": list(needs), "allows": list(allows)}
        declared.append(fn)
        return fn
    return register


class Ended(BaseException):
    """The run is over. A BaseException, so a recipe's `except Exception`
    cannot swallow it."""

    def __init__(self, how):
        super().__init__(how)
        self.how = how


class Element(dict):
    """Something on screen. `x` and `y` are its centre, in screen points."""

    def __getattr__(self, key):
        try:
            return self[key]
        except KeyError:
            raise AttributeError(key)

    @property
    def left(self):
        return self["x"] - self["w"] / 2

    @property
    def top(self):
        return self["y"] - self["h"] / 2

    @property
    def right(self):
        return self["x"] + self["w"] / 2

    @property
    def bottom(self):
        return self["y"] + self["h"] / 2


def _elements(reply, key="items"):
    return [Element(item) for item in reply.get(key) or []]


def _one(reply, key="item"):
    item = reply.get(key)
    return Element(item) if item else None


class Ask:
    """What was asked: the sentence and what Jev read out of it."""

    def __init__(self, request, who=(), what=""):
        self.text = request.get("run", "")
        self.who = list(who)
        self.what = what
        self.app = request.get("app", "")
        self.letters = request.get("letters", 2)
        self.screen = request.get("screen") or {"w": 0, "h": 0}


class App:
    """`call(do, **args)` sends one step and returns the reply. `choose(question,
    among, typed, waited)` asks Jev. Both come from the runner."""

    def __init__(self, call, choose, name=""):
        self._call = call
        self._choose = choose
        self._name = name
        self._waited = 0

    # Keys and text

    def key(self, keys, wait=0):
        """A shortcut, such as "cmd+n", "return", "delete", "escape"."""
        self._call("key", keys=keys, wait=wait)

    def type(self, text):
        """Real keystrokes, one letter at a time. For a field that filters a
        list as you type, such as a recipient field."""
        self._call("type", text=text)

    def paste(self, text):
        """Text through the clipboard. For anything longer than a few letters."""
        self._call("paste", text=text)

    def wait(self, ms):
        self._call("wait", ms=ms)

    # Seeing

    def lookup_field(self):
        """The field the caret is in, when it looks things up (To, search).
        None when the caret is anywhere else."""
        return _one(self._call("lookup_field"))

    def find(self, role=None, name=None, kind=None):
        """Everything in the front window that matches. `name` is a
        case-insensitive substring. `kind` is "click", "text" or "label"."""
        return _elements(self._call("find", role=role, name=name, kind=kind))

    def frames(self, role):
        """Where every element with this role is, including ones `find` leaves
        out because they are large, such as a table."""
        return _elements(self._call("frames", role=role))

    def pressable_at(self, x, y):
        """The thing that can be pressed at a point, if any."""
        return _one(self._call("pressable_at", x=x, y=y))

    def mark(self):
        """Remember what is on screen now, to compare against later."""
        return self._call("mark")["mark"]

    def rows(self, since, under, outside_window=False, ms=3000):
        """The list that typing into `under` opened. `outside_window` for an
        app whose list is not inside its window, such as Outlook."""
        reply = self._call("rows", since=since, under=under["id"],
                           outside_window=outside_window, ms=ms)
        self._waited = reply.get("waited", 0)
        return _elements(reply)

    def appeared(self, since, ms=2000, settle=False, windows=False):
        """What can be clicked now that was not there at `since`. `settle`
        waits until the count stops growing; `windows` includes new windows,
        such as a menu."""
        reply = self._call("appeared", since=since, ms=ms, settle=settle, windows=windows)
        self._waited = reply.get("waited", 0)
        return _elements(reply)

    def on_line(self, name, field):
        """Whether `name` now sits on the recipient line: in the field's own
        value, as Slack shows it, or as a token beside it, as Outlook does."""
        try:
            items = self._call("snapshot", at=[0, 0], app=self._name)["snapshot"]["items"]
        except RuntimeError:
            return False
        wanted = name.lower()
        line = field["y"] if field else 0
        for item in items:
            if wanted not in (item["name"] + " " + item["value"]).lower():
                continue
            if item.get("lookup"):
                return True
            if field and abs(item["y"] - line) <= 25 and not item.get("in_list"):
                return True
        self.say(f"  focus: {self._call('focus').get('described', '')}")
        return False

    # Deciding

    def choose(self, question, among, typed=""):
        """Ask Jev which element answers the question. None when none does."""
        return self._choose(question, list(among), typed, self._waited)

    # Acting

    def click(self, element):
        self._call("click", id=element["id"])

    def click_at(self, x, y):
        self._call("click_at", x=x, y=y)

    def right_click(self, x, y):
        self._call("right_click", x=x, y=y)

    def hover(self, x, y):
        self._call("hover", x=x, y=y)

    def drag(self, start, end):
        self._call("drag", start=list(start), end=list(end))

    # Ending

    def say(self, line):
        self._call("say", text=line)

    def ready(self, element):
        """Put the caret in `element` and end the run: the words are yours."""
        self._call("ready", id=element["id"])
        raise Ended("ready")

    def done(self, line):
        self.say(f"done       {line}")
        raise Ended("done")

    def stop(self, reason):
        self.say(f"✗ {reason}")
        raise Ended("stopped")
