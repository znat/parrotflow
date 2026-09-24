"""The action runner. One process, started by ParrotFlow, serving one request
at a time. It decides; the app only touches the screen.

It imports the recipe files, asks Jev which recipe fits and what was said, and
calls the recipe in this process. When no recipe fits it runs the loop
(`loop.py`, deciding with `decider.py`). Every screen action is a step the
app does and answers.

Protocol, one JSON object per line. The runner writes on stdout, the app on
stdin:

    runner  {"up": <pid>}                                  once, at start
    app     {"run": "<utterance>", "app": "Slack", "bundle": "com.tinyspeck.slackmacgap",
             "gaze": [x, y] | null, "letters": 2, "screen": {"w": .., "h": ..},
             "execute": true, "recipes": true, "read_app": "Slack" | null,
             "loop": {"max_steps": 30, "send": false, "spotlight": 0, "lookup_letters": 2}}
    runner  {"do": "<step>", ...}                          any number of times
    app     {"ok": true, ...} | {"error": "...", "said": true|false, "text": "..."}
    runner  {"end": "planned|ready|done|stopped|failed", "ok": bool, "loop": {...}}

`recipes: false` skips the recipes and goes straight to the loop. `loop` in
the end message is the loop's report, when the loop ran: `said`, `markdown`,
`acted`, `stopped`, `steps`, `shown`. An error with `said: true` was already
shown (Escape, a refused click, the app not in front): the run ends as
stopped. Any other error raises in the recipe. EOF on stdin ends the process.

    runner  {"do": "ask", "question": "..", "options": [..], "near": {x, y, w, h} | null,
             "shown": [..]}
    app     {"answer": "..", "via": "option|text|voice"} | {"answer": null, "via": "escape|timeout"}

A question for the user, in a panel next to `near`: x, y is the centre and w,
h the size, in screen points, as for items. Null puts it in the middle of the
screen. `options` are at most 4; the app adds "Something else…", which takes
typed words. `shown` is the steps done so far, as the report reads them; a
`key` or `press` step carries it too, for the questions the app asks itself.
The app gives up after 60 s. A guard's question has the options "Yes, go
ahead" and "No". That option or a plain yes is yes; "No", a plain no, Escape
or silence is no; other words steer. The app's own guards (Return, never_press)
then reply {"error": "redirected", "text": "<the words>"}, not said: the step
is not done and the run goes on.

`focus` replies {"point": [x, y] | null, "described": "..", "role": "AXTextField" | null}.

    runner  {"do": "progress", "title": "<utterance>", "activity": ".." | null,
             "plan": [{"content": "..", "status": "pending|in_progress|completed|cancelled",
                       "notes": [".."]}] | null,
             "outcome": ".." | null}
    app     {"ok": true}

The run panel's state, whole each time. The app shows it; the reply is not
read for anything. `title` is the request, which the app shortens. `plan` is
the agent's task list, null on the other paths. `notes` are the last two
things that went wrong while that task was in progress: a failed step, a
repeat, a refused `done`, the reason the run stopped. `activity` is the step
being done, "thinking…" while the model is asked, "asking you…" during a
question. `outcome` is set once, at the end, before the `end` message.
Sent at most every 100 ms; a newer state waits for the next message, and
the state before a wait (thinking, asking, the end) is sent at once.

`steers: true`, sent by the agent, shows a text field under the plan: the
user can type to the run, or hold the action key and speak. Each message is
queued in the app.

    runner  {"do": "steer"}
    app     {"messages": [".."]}

The messages sent since the last `steer`, oldest first, and the queue is
emptied. The agent asks before each model call and adds each as a user
message. While the field has focus or holds unsent text, a step that touches
the screen (a key, typing, a paste, a click at a point, a drag, a menu) waits.
Its reply then carries `paused_ms`, the time it waited, which the agent does
not count against its time limit. Escape in an empty field stops the run.

    app     {"decide": "<utterance>", "snapshot": {...}, "done": [..],
             "mode": "decide|look|request"}
    runner  {"end": "decided", "ok": true, "offers": [..], "decision": {..} | "body": ".."}

A decision on a window the app hands over, for `--act`. No step is asked for.

    runner  {"do": "look", "x": .., "y": .., "w": .., "h": ..}
    app     {"lines": [{"text": "..", "x", "y", "w", "h", "p"}]} | {"error": ".."}

The text in a part of the screen, read from its pixels. The region and each
line's frame are centre and size in screen points, as for items. `p` is
Vision's confidence. Needs Screen Recording; without it the error is
"screen recording is not granted".

Set by the app at start: PARROTFLOW_JEV_KEY, PARROTFLOW_JEV_KEY_SOURCE,
PARROTFLOW_JEV_URL, PARROTFLOW_JEV_MODEL, PARROTFLOW_JEV_TIMEOUT,
PARROTFLOW_RECIPES_USER, PARROTFLOW_APP_NOTES. When `actions.planner` is set,
also the PARROTFLOW_PLANNER_* settings (see `planner.py`): the loop then asks
the planner for steps and Jev only finds each target. When `actions.record` is
on, PARROTFLOW_RUNS: the folder each run is recorded in (see `runlog.py`). The
app then answers a `snapshot` that carries `shot` (a file path) with the
screenshot written there, `shot: {file, frame, scale, w, h}`, or `shot: null`
and `shot_error`; `press` and `click_at` add `under`, what the hit test found
at the point before.

A `snapshot` with `see: true` also carries, when `actions.see` is on and
Screen Recording is granted, `seen`: the window's text lines as `look` gives
them, read from the same capture, and `seen_ms`. Without it there is no
`seen`.
"""

import importlib.util
import json
import os
import sys
import tempfile
import time
import traceback
import unicodedata

_out = sys.stdout
sys.stdout = sys.stderr

import parrotflow  # noqa: E402
from parrotflow import App, Ask, Ended  # noqa: E402

NEEDS = ""
# Pydantic AI prints a banner on the first run. stdout is the app's channel.
os.environ.setdefault("PYDANTIC_AI_NO_BANNER", "1")
PACKAGES = {"pydantic": "pydantic", "openai": "openai",
            "pydantic_ai": "pydantic-ai-slim[openai,typesafe]",
            "typesafe_sdk": "pydantic-ai-slim[openai,typesafe]",
            "pydantic_ai_harness": "pydantic-ai-harness"}
try:
    import judge
    import loop
    from judge import Failure
    import planner as planning
    import runlog as recording
    # 330-520 ms, once per runner, instead of on the first agent run.
    import agent  # noqa: F401
except ImportError as error:
    missing = (error.name or "").split(".")[0]
    if missing not in PACKAGES:
        raise
    judge = loop = planning = recording = None
    NEEDS = (f"the action runner needs {PACKAGES[missing]}: python3 -m pip install "
             + " ".join(f"'{p}'" if "[" in p else p for p in dict.fromkeys(PACKAGES.values())))

BUILT_IN = os.path.dirname(os.path.abspath(__file__))
PROGRESS_EVERY = 0.1
NOT_RECIPES = {"parrotflow.py", "runner.py", "decider.py", "loop.py", "planner.py", "agent.py",
               "runlog.py", "judge.py", "ground.py", "ground_server.py"}


class Gone(BaseException):
    """The app closed stdin."""


# Questions to Jev


def pick_recipe(utterance, options, jev):
    """Which recipe the request is, or none."""
    criteria = dict(options)
    criteria["none"] = "none of these — something else"
    answer = judge.timed("recipe", jev, {"utterance": utterance}, {
        "recipe": judge.Pick("Which of these is the user asking for?", criteria)})["recipe"]
    return answer.value, answer.p


# Measured 6/6 on 2026-09-21 in English and French with these two keys and
# this wording. The first wording of `what` scored a message body 0.54-0.71 as
# `none`; "if this word would appear in the message box" moved the same words
# to 0.91-0.99.
_ENTITY_KEYS = {
    "who": "part of the name of a person, channel or conversation to be found and picked on screen",
    "what": "one of the user's own words that is to end up on screen: a word of the message they "
            "are dictating, or a word of what they want looked up. If this word would appear in the "
            "message box or the search box, it is `what`.",
    "none": "a word of the instruction itself -- the verb, a preposition, a filler. It tells the "
            "computer what to do and never appears on screen.",
}


def _strip_punctuation(word):
    start, end = 0, len(word)
    while start < end and unicodedata.category(word[start]).startswith("P"):
        start += 1
    while end > start and unicodedata.category(word[end - 1]).startswith("P"):
        end -= 1
    return word[start:end]


def entities(utterance, jev):
    """Who to find and what to write. Jev assigns a key to each word; the
    code joins them. One entry per person in `who`."""
    words = [w for w in utterance.split(" ") if w]
    if not words:
        return [], ""
    questions = {}
    for index, word in enumerate(words):
        questions[f"w{index}"] = judge.Pick(
            f"What is the word “{word}” (w{index}) in this utterance?", _ENTITY_KEYS)
    state = {
        "utterance": utterance,
        "note": "The user looks at the screen and says this. Some words are things to be used "
                "literally -- a name to find, words to type. The rest is the request.",
        "words": {f"w{index}": word for index, word in enumerate(words)},
    }
    answers = judge.timed("entities", jev, state, questions)

    who, run, said = [], [], []
    for index, word in enumerate(words):
        key = answers[f"w{index}"].value
        clean = _strip_punctuation(word)
        if key == "who":
            run.append(clean)
            # A comma ends a name even when the next word is a name too:
            # without this, "Alex, Peter and Antonio Ruiz" came out as
            # "Alex Peter" and "Antonio Ruiz".
            if word.endswith(",") or word.endswith(";"):
                who.append(" ".join(run))
                run = []
        else:
            if run:
                who.append(" ".join(run))
                run = []
            if key == "what":
                said.append(word)
    if run:
        who.append(" ".join(run))
    return who, " ".join(said)


def _role(element):
    return str(element.get("role", "")).replace("AX", "")


def choose(question, among, typed, waited, jev, say):
    """One question over a short list. The element Jev chose, or None."""
    index, p = None, 0.0
    if among:
        criteria = {"none": "none of these is it"}
        for i, element in enumerate(among):
            name = element.get("name") or element.get("value") or ""
            criteria[f"r{i}"] = f"{_role(element)} “{name[:90]}”"
        try:
            pick = judge.timed("choose", jev, {"question": question},
                               {"pick": judge.Pick(question, criteria)})["pick"]
        except Failure as error:
            say(f"✗ the question failed: {error}")
            return None
        chosen, p = pick.value, pick.p
        if chosen != "none" and chosen[1:].isdigit() and int(chosen[1:]) < len(among):
            index = int(chosen[1:])
    if index is None:
        say(f"✗ none of the {len(among)} rows fits ({p:.2f}):")
        for row in among[:6]:
            say(f"    {_role(row)} “{str(row.get('name', ''))[:40]}”")
        return None
    row = among[index]
    say(f"step       {typed[:24]} → “{str(row.get('name', ''))[:40]}” of {len(among)} rows "
        f"({_role(row)}), {p:.2f}, after {waited} ms")
    return row


# Recipes


def declared_in(path, index):
    """The recipes a file declares with @recipe. A file that fails to import is
    logged and skipped, so one broken file does not take the others down."""
    parrotflow.declared.clear()
    spec = importlib.util.spec_from_file_location(f"recipe_file_{index}", path)
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception:
        print(f"{path} did not load:")
        traceback.print_exc()
        return []
    finally:
        found = list(parrotflow.declared)
        parrotflow.declared.clear()
    return [dict(fn.recipe, key=fn.recipe["name"], run=fn, path=path) for fn in found]


def recipes_for(app, bundle=""):
    """Built-in first, then the user's folder: a user recipe with the same name
    and app wins. Imported on every request, so an edit counts on the next one."""
    by_key = {}
    roots = [BUILT_IN, os.environ.get("PARROTFLOW_RECIPES_USER", "")]
    index = 0
    for root in roots:
        if not root or not os.path.isdir(root):
            continue
        for folder, dirs, files in os.walk(root):
            dirs[:] = sorted(d for d in dirs if d != "__pycache__")
            for name in sorted(files):
                if not name.endswith(".py") or (folder == BUILT_IN and name in NOT_RECIPES):
                    continue
                index += 1
                for recipe in declared_in(os.path.join(folder, name), index):
                    if recipe["app"] in (app, bundle) and recipe["app"]:
                        by_key[recipe["key"]] = recipe
    return [by_key[key] for key in sorted(by_key)]


# Serving


class Channel:
    def __init__(self, inp, out):
        self.inp = inp
        self.out = out
        self.recorder = recording.OFF if recording else None
        self.state = {}
        self.shown = None
        self.sent_at = 0.0
        # Where each read's picture goes when runs are not recorded and the
        # agent needs one. Overwritten by the next read.
        self.shots = None
        # Seconds the app held screen steps while the user typed to the run.
        self.paused = 0.0

    def send(self, message):
        self.out.write(json.dumps(message) + "\n")
        self.out.flush()

    def read(self):
        while True:
            line = self.inp.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                continue
            try:
                return json.loads(line)
            except ValueError:
                print(f"not JSON from the app: {line[:120]}")

    def progress(self, now=False, **fields):
        """The run panel's state, merged with what was set before. `now`
        sends it at once: a wait follows."""
        self.state.update(fields)
        if now or time.monotonic() - self.sent_at >= PROGRESS_EVERY:
            self._flush()

    def _flush(self):
        if not self.state:
            return
        said = json.dumps(self.state, ensure_ascii=False)
        if said == self.shown:
            return
        self.shown = said
        self.sent_at = time.monotonic()
        self.send(dict(self.state, do="progress"))
        if self.read() is None:
            raise Gone()

    def begin(self, title):
        self.state = {"title": title, "plan": None, "activity": "reading the screen…",
                      "outcome": None}
        self.shown = None
        self.paused = 0.0
        self._flush()

    def ask(self, do, **args):
        """One step, and the reply as it came."""
        self._flush()
        recorder = self.recorder
        if do == "snapshot" and recorder.live:
            args["shot"] = recorder.shot_path()
        elif do == "snapshot" and self.shots:
            args["shot"] = self.shots
        args["do"] = do
        started = time.monotonic()
        self.send(args)
        reply = self.read()
        if reply is None:
            raise Gone()
        recorder.saw(do, args, reply, int((time.monotonic() - started) * 1000))
        if isinstance(reply.get("paused_ms"), (int, float)):
            self.paused += reply["paused_ms"] / 1000
        return reply

    def call(self, do, **args):
        reply = self.ask(do, **args)
        if reply.get("error"):
            if reply.get("said"):
                raise Ended("stopped")
            if reply["error"] == "redirected":
                raise RuntimeError(f"Not done — the user said: \"{reply.get('text', '')}\"")
            raise RuntimeError(reply.get("text") or reply["error"])
        return reply


def serve(request, channel, jev, planner=None):
    """One request. Returns the end message."""
    def log(line):
        try:
            channel.ask("log", text=line, plain=True)
        except Gone:
            pass

    recorder = recording.Recorder.start(
        os.environ.get("PARROTFLOW_RUNS", ""), request,
        model=planner.model if planner else jev.model,
        secrets=[jev.key, planner.key if planner else ""], log=log)
    channel.recorder = recorder
    if planner is not None:
        planner.recorder = recorder
    ended = {"end": "failed"}
    try:
        channel.begin(request.get("run", ""))
        how = pick_and_run(request, channel, jev)
        if how != "none":
            ended = {"end": how}
            outcome = OUTCOMES.get(how, how)
            said = channel.state.get("activity") or ""
            if how in ("stopped", "failed") and said.startswith("✗"):
                outcome += " — " + said[1:].strip()
        else:
            how, report = loop.run(request, channel, jev, planner)
            ended = {"end": how, "loop": report.as_dict()}
            outcome = report.stopped or report.said or OUTCOMES.get(how, how)
        channel.progress(now=True, activity=None, outcome=outcome)
        return ended
    finally:
        channel.state, channel.shown = {}, None
        channel.recorder = recording.OFF
        if planner is not None:
            planner.recorder = recording.OFF
        recorder.finish(ended)


OUTCOMES = {"done": "Done", "ready": "Ready — dictate", "planned": "Planned only",
            "stopped": "Stopped", "failed": "Failed"}


def pick_and_run(request, channel, jev):
    """The recipe for the request, run. `none` when no recipe fits."""
    def call(do, **args):
        if do == "say":
            channel.progress(activity=" ".join(str(args.get("text", "")).split()))
        return channel.call(do, **args)

    def say(line):
        call("say", text=line)

    app_name = request.get("app", "")
    utterance = request.get("run", "")
    if not request.get("recipes", True):
        return "none"
    recipes = recipes_for(app_name, request.get("bundle", ""))
    if not recipes:
        return "none"
    try:
        try:
            options = {}
            for recipe in recipes:
                options.setdefault(recipe["key"], recipe["says"])
            key, p = pick_recipe(utterance, options, jev)
        except Failure as error:
            say(f"✗ could not pick a recipe: {error}")
            return "failed"
        recipe = next((r for r in recipes if r["key"] == key), None)
        if key == "none" or recipe is None:
            return "none"
        say(f"recipe     {key} in {app_name} ({p:.2f})")
        channel.recorder.update(kind="recipe", recipe=key)
        channel.call("log", text=f"from {recipe['path']}")

        who, what = [], ""
        if recipe["needs"]:
            try:
                who, what = entities(utterance, jev)
            except Failure as error:
                say(f"✗ could not read what was said: {error}")
                return "failed"
        if who:
            say("who        " + ", ".join(f"\u201c{name}\u201d" for name in who))
        if what:
            say(f"what       \u201c{what}\u201d")
        if not request.get("execute", True):
            say("(planned only)")
            return "planned"

        channel.call("begin", allows=recipe["allows"])
        app = App(call, lambda q, among, typed, waited:
                  choose(q, among, typed, waited, jev, say), name=app_name)
        recipe["run"](app, Ask(request, who, what))
        return "done"
    except Ended as ended:
        return ended.how
    except SystemExit as exit_:
        return "failed" if exit_.code else "done"
    except Exception as error:
        traceback.print_exc()
        last = traceback.format_exception_only(type(error), error)[-1].strip()
        try:
            say(f"✗ the recipe failed: {last}")
        except Ended:
            pass
        return "failed"


def refuse(channel, why):
    """Every request ends at once with `why`: the runner cannot act."""
    print(why)
    channel.send({"up": os.getpid()})
    while True:
        request = channel.read()
        if request is None:
            return
        if "decide" in request:
            channel.send({"end": "failed", "ok": False, "error": why})
        elif "run" in request:
            channel.send({"do": "say", "text": f"✗ {why}"})
            if channel.read() is None:
                return
            channel.send({"end": "failed", "ok": False})


def main():
    channel = Channel(sys.stdin, _out)
    if NEEDS:
        return refuse(channel, NEEDS)
    jev = judge.Jev.from_env()
    planner = planning.Planner.from_env()
    if planner is not None and planner.loop == "agent":
        channel.shots = os.path.join(tempfile.gettempdir(), f"parrotflow-shot-{os.getpid()}.jpg")
    channel.send({"up": os.getpid()})
    while True:
        request = channel.read()
        if request is None:
            return
        if "decide" in request:
            try:
                channel.send(decide(request, channel, jev))
            except Gone:
                return
            continue
        if "run" not in request:
            print(f"not a request: {json.dumps(request)[:120]}")
            continue
        try:
            ended = serve(request, channel, jev, planner)
        except Gone:
            return
        ended["ok"] = ended["end"] in ("planned", "ready", "done")
        channel.send(ended)


def decide(request, channel, jev):
    try:
        reply = loop.decide_only(
            request, jev, lambda line: channel.call("log", text=line, plain=True))
    except Failure as error:
        return {"end": "failed", "ok": False, "error": str(error)}
    except Exception as error:
        traceback.print_exc()
        return {"end": "failed", "ok": False, "error": f"{type(error).__name__}: {error}"}
    reply.update({"end": "decided", "ok": True})
    return reply


if __name__ == "__main__":
    main()
