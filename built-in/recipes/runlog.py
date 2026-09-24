"""Run recordings, for `scripts/trace-viewer`. One folder per run:

    <runs>/<time>-<request>/run.json      the request, the settings, how it ended
                            calls/NN.json  a model call: messages as sent, tool calls, results,
                                           the agent's plan
                            steps/NN.json  a step done on screen, and what it changed
                            trees/NN.json  a read of the window: every item, raw
                            shots/NN.jpg   its screenshot, cut to the window
                                           (the tree's `seen`: the text in it)
                            looks/NN.json  text read from the pixels
                            grounds/NN.json a point found in the pixels (`ground`), or the
                                           picture shown to the model on a stuck turn
                            grounds/NN.jpg the JPEG sent to the model, when one was
                            review.json    the review after the run (`review.py`)

The app sets PARROTFLOW_RUNS to the folder when `actions.record` is on. No
folder, no recording. The runner hooks `Channel.ask`: every snapshot the app
answers becomes a tree, every look a look, and every verb that touches the
screen a part of the open step. `Loop._planned_step` opens and closes steps.
Outside a step (recipes, the Jev loop) each such verb is a step of its own.

Every record has `seq`, one counter for the whole run: the viewer orders by it.
A write that fails is logged once, and the run goes on unrecorded. The keys
are replaced before anything is written.
"""

import datetime
import json
import os
import re
import shutil
import time
from typing import Any, Dict, List, Optional, Union

from pydantic import BaseModel, Field

KEEP = 50
FOLDER = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}")
# Verbs that touch the screen. Each is a part of a step.
ACTIONS = {"press", "click", "click_at", "right_click", "hover", "drag", "key", "type", "paste",
           "scroll", "select", "show_menu", "ready"}


class Run(BaseModel):
    request: str
    app: str
    bundle: str
    started: str
    kind: str = ""                  # agent | plan | loop | recipe
    recipe: str = ""
    model: str = ""
    settings: Dict[str, Any] = Field(default_factory=dict)
    gaze: Any = None
    screen: Any = None
    ended: Optional[str] = None     # null while the run goes on
    end: Optional[str] = None       # planned | ready | done | stopped | failed
    outcome: str = ""               # the report's `stopped`
    said: str = ""
    shown: List[str] = Field(default_factory=list)
    calls: int = 0
    steps: int = 0
    trees: int = 0
    looks: int = 0
    grounds: int = 0


class Call(BaseModel):
    n: int
    seq: int
    at: str
    kind: str                       # agent | plan | review
    messages: List[Any]             # as sent, after history cutting
    tool_calls: List[Any] = Field(default_factory=list)
    tools: List[Any] = Field(default_factory=list)    # {name, args}, args parsed
    results: List[Any] = Field(default_factory=list)
    reply: Any = None               # the plan path's answer
    ms: int = 0
    tokens: Dict[str, Optional[int]] = Field(default_factory=dict)
    # The screen the model saw: its tree, and model ID to item id. A line
    # `look` saw has no item id; it is in `seen`, whole.
    tree: Optional[int] = None
    ids: Dict[str, Any] = Field(default_factory=dict)
    seen: Dict[str, Any] = Field(default_factory=dict)
    steps: List[int] = Field(default_factory=list)
    error: str = ""
    plan: List[Any] = Field(default_factory=list)   # the agent's tasks after the call
    steer: List[str] = Field(default_factory=list)  # what the user typed or said during the run


class Step(BaseModel):
    n: int
    seq: int
    at: str
    call: Optional[int] = None
    do: str = ""
    value: str = ""
    planned: Any = None             # the step as asked for
    target: Any = None              # the item, as the tree had it
    point: Any = None               # [x, y] in screen points
    pressed: Optional[bool] = None  # true: an accessibility press; false: a real click
    under: Any = None               # what the hit test found at the point before
    actions: List[Any] = Field(default_factory=list)  # the verbs sent, and the replies
    asked: List[Any] = Field(default_factory=list)    # guard questions and answers
    tree_before: Optional[int] = None
    tree_after: Optional[int] = None
    change: Any = None
    sentence: str = ""
    outcome: str = ""
    error: str = ""
    ms: int = 0                     # with the expect check
    expect: str = ""                # what the agent said should be true after it
    expect_p: Optional[float] = None    # Jev's yes to it
    expect_ms: int = 0
    lost: str = ""                  # what the step took out of its field


class Tree(BaseModel):
    n: int
    seq: int
    at: str
    snapshot: Any                   # as the app sent it: every item, and the window frame
    shot: Any = None                # {file, frame, scale, w, h}: frame in screen points
    shot_error: str = ""
    scale: Union[int, float, None] = None   # pixels per point
    # The window's text read from the same capture: {text, x, y, w, h, p},
    # in screen points. None when it was not read.
    seen: Optional[List[Any]] = None
    seen_ms: Optional[int] = None
    call: Optional[int] = None
    step: Optional[int] = None


class Look(BaseModel):
    n: int
    seq: int
    at: str
    region: Any
    lines: List[Any] = Field(default_factory=list)
    error: str = ""
    tree: Optional[int] = None
    call: Optional[int] = None
    step: Optional[int] = None


class Ground(BaseModel):
    n: int
    seq: int
    at: str
    method: str                     # tinyclick | luna | image: a picture for a stuck turn,
                                    # or a point the model read off it
    description: str = ""
    why: str = ""                   # a stuck turn: what made it one
    region: Any = None              # the crop, centre and size in screen points
    crop: Any = None                # the crop in the shot's pixels, x, y its top left
    shot: str = ""                  # the screenshot it was cut from
    point: Any = None               # [x, y] in screen points; null: not found
    image: str = ""                 # the JPEG the model got, in this folder
    raw: Any = None                 # the model's answer as it came
    ms: int = 0
    tokens: Optional[Dict[str, Optional[int]]] = None
    error: str = ""
    tree: Optional[int] = None
    call: Optional[int] = None
    step: Optional[int] = None


def _now():
    return datetime.datetime.now().astimezone().isoformat(timespec="milliseconds")


def _slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:40].strip("-") or "run"


def prune(root, keep):
    """Deletes the oldest run folders so `keep` are left. Only folders named
    like a run: a mistyped root must not lose anything else."""
    runs = sorted(n for n in os.listdir(root)
                  if FOLDER.match(n) and os.path.isdir(os.path.join(root, n)))
    for name in runs[:max(0, len(runs) - keep)]:
        shutil.rmtree(os.path.join(root, name), ignore_errors=True)


class Recorder:
    def __init__(self, folder=None, secrets=(), log=None):
        self.folder = folder
        self.secrets = [s for s in secrets if s]
        self.log = log or (lambda line: None)
        self.dead = folder is None
        self.failed = False
        self.run = None
        self.seq = 0
        self.counts = {"calls": 0, "steps": 0, "trees": 0, "looks": 0, "grounds": 0}
        self.calling = None
        self.step = None
        self.ended_step = None
        self.step_started = 0.0
        self.last_tree = None
        self.trees_by_snapshot = {}
        self.items = {}
        self.step_calls = {}

    @classmethod
    def start(cls, root, request, model="", secrets=(), log=None, keep=KEEP):
        """The recorder for one run. A dead one when `root` is empty or cannot
        be written: every method then does nothing."""
        if not root:
            return cls()
        recorder = cls(None, secrets, log)
        started = datetime.datetime.now()
        try:
            os.makedirs(root, exist_ok=True)
            prune(root, keep - 1)
            said = request.get("run", "")
            for secret in recorder.secrets:
                said = said.replace(secret, "")
            name = f"{started:%Y-%m-%dT%H-%M-%S}.{started.microsecond // 1000:03d}-" + _slug(said)
            folder = os.path.join(root, name)
            n = 1
            while os.path.exists(folder):
                n += 1
                folder = os.path.join(root, f"{name}-{n}")
            os.makedirs(folder)
            for part in ("calls", "steps", "trees", "shots", "looks", "grounds"):
                os.makedirs(os.path.join(folder, part))
            run = Run(
                request=request.get("run", ""), app=request.get("app", ""),
                bundle=request.get("bundle", ""), started=_now(), model=model,
                settings=dict(request.get("loop") or {}, execute=request.get("execute", True),
                              recipes=request.get("recipes", True),
                              read_app=request.get("read_app")),
                gaze=request.get("gaze"), screen=request.get("screen"))
        except Exception as error:
            recorder._failed(error)
            return recorder
        recorder.folder = folder
        recorder.dead = False
        recorder.run = run
        recorder._save_run()
        return recorder

    @property
    def live(self):
        return not self.dead

    # Writing

    def _failed(self, error):
        self.dead = True
        if self.failed:
            return
        self.failed = True
        try:
            self.log(f"recorder: this run is not recorded from here on — {error}")
        except Exception:
            pass

    def _write(self, path, record):
        if self.dead:
            return
        try:
            data = record if isinstance(record, dict) else record.model_dump()
            text = json.dumps(data, ensure_ascii=False, indent=1, default=str)
            for secret in self.secrets:
                text = text.replace(secret, "[key]")
            full = os.path.join(self.folder, path)
            with open(full + ".tmp", "w", encoding="utf-8") as handle:
                handle.write(text)
            os.replace(full + ".tmp", full)
        except Exception as error:
            self._failed(error)

    def _save_run(self):
        if self.run is None:
            return
        for key, count in self.counts.items():
            setattr(self.run, key, count)
        self._write("run.json", self.run)

    def _next(self, kind):
        self.counts[kind] += 1
        self.seq += 1
        return self.counts[kind], self.seq

    # The run

    def update(self, **fields):
        if self.dead or self.run is None:
            return
        for key, value in fields.items():
            setattr(self.run, key, value)
        self._save_run()

    def finish(self, ended):
        if self.dead or self.run is None:
            return
        if self.step is not None:
            self.end_step(error="the run ended inside the step")
        report = ended.get("loop") or {}
        self.run.ended = _now()
        self.run.end = ended.get("end")
        self.run.outcome = report.get("stopped", "")
        self.run.said = report.get("said") or ""
        self.run.shown = list(report.get("shown") or self.run.shown)
        self._save_run()

    # What the app answered

    def shot_path(self):
        """Where the app writes the next tree's screenshot, or None."""
        if self.dead:
            return None
        return os.path.join(self.folder, "shots", f"{self.counts['trees'] + 1:02d}.jpg")

    def saw(self, do, args, reply, ms):
        """One verb and the app's reply, from `Channel.ask`."""
        if self.dead or not isinstance(reply, dict):
            return
        try:
            if do == "snapshot" and isinstance(reply.get("snapshot"), dict):
                self._tree(reply)
            elif do == "look":
                self._look(args, reply)
            elif do == "ask" and self.step is not None:
                self.step.asked.append({"question": args.get("question"),
                                        "options": args.get("options"),
                                        "answer": reply.get("answer"),
                                        "via": reply.get("via") or reply.get("error")})
            elif do in ACTIONS:
                self._action(do, args, reply, ms)
        except Exception as error:
            self._failed(error)

    def _tree(self, reply):
        n, seq = self._next("trees")
        snapshot = reply["snapshot"]
        shot = reply.get("shot")
        if isinstance(shot, dict) and shot.get("file"):
            shot = dict(shot, file=os.path.relpath(shot["file"], self.folder))
        else:
            shot = None
        tree = Tree(n=n, seq=seq, at=_now(), snapshot=snapshot, shot=shot,
                    shot_error=str(reply.get("shot_error") or ""),
                    scale=(shot or {}).get("scale") or reply.get("scale"),
                    seen=reply.get("seen") if isinstance(reply.get("seen"), list) else None,
                    seen_ms=reply.get("seen_ms"),
                    call=self.calling, step=self.step.n if self.step else None)
        self.last_tree = n
        self.trees_by_snapshot[snapshot.get("id")] = n
        for item in snapshot.get("items") or ():
            if isinstance(item, dict) and "id" in item:
                self.items[item["id"]] = item
        self._write(f"trees/{n:02d}.json", tree)
        self._save_run()

    def _look(self, args, reply):
        n, seq = self._next("looks")
        look = Look(n=n, seq=seq, at=_now(),
                    region={k: args.get(k) for k in ("x", "y", "w", "h")},
                    lines=reply.get("lines") or [], error=str(reply.get("error") or ""),
                    tree=self.last_tree, call=self.calling,
                    step=self.step.n if self.step else None)
        self._write(f"looks/{n:02d}.json", look)

    def _action(self, do, args, reply, ms):
        sent = {k: v for k, v in args.items() if k not in ("do", "shown")}
        alone = self.step is None
        if alone:
            self.begin_step({"do": do, "value": sent.get("text") or sent.get("keys") or ""})
        step = self.step
        step.actions.append({"do": do, "args": sent, "reply": reply, "ms": ms})
        if do in ("press", "click", "ready") and step.target is None:
            step.target = self.items.get(sent.get("id"))
        if do in ("click_at", "right_click") and step.target is None:
            step.target = {"kind": "seen", "role": "Seen", "name": sent.get("name", ""),
                           "x": sent.get("x"), "y": sent.get("y"), "w": 0, "h": 0}
        if do in ("press", "click", "click_at", "right_click", "ready", "scroll", "hover"):
            point = reply.get("at") or ([sent["x"], sent["y"]] if "x" in sent else None)
            if point is None and step.target:
                point = [step.target.get("x"), step.target.get("y")]
            step.point = point
            step.pressed = bool(reply.get("pressed")) if do == "press" else \
                None if do in ("scroll", "hover") else False
            if reply.get("under"):
                step.under = reply["under"]
        if reply.get("error"):
            step.error = str(reply.get("text") or reply["error"])
        if alone:
            self.end_step()

    def ground(self, record, image=None):
        """One grounding: `record` as `Ground` has it, and the JPEG the model
        got. The JPEG's path in the run folder, or None."""
        if self.dead:
            return None
        try:
            n, seq = self._next("grounds")
            name = f"grounds/{n:02d}.jpg" if image else ""
            if image:
                with open(os.path.join(self.folder, name), "wb") as handle:
                    handle.write(image)
            shot = record.get("shot") or ""
            if shot and os.path.isabs(shot):
                shot = os.path.relpath(shot, self.folder)
            self._write(f"grounds/{n:02d}.json", Ground(
                n=n, seq=seq, at=_now(), **dict(record, shot=shot, image=name),
                tree=self.last_tree, call=self.calling, step=self.step.n if self.step else None))
            self._save_run()
            return name or None
        except Exception as error:
            self._failed(error)
            return None

    # Model calls

    def begin_call(self, n):
        """Before a model call is sent: steps from here belong to it."""
        if self.dead:
            return None
        self.calling = n
        self.seq += 1
        return {"seq": self.seq, "at": _now()}

    def screen(self, snapshot, ids):
        """The screen as the model got it: model ID to item id."""
        if self.dead:
            return {}
        out = {"tree": self.trees_by_snapshot.get(snapshot.get("id"), self.last_tree),
               "ids": {}, "seen": {}}
        for n, item in ids.items():
            if item.get("kind") == "seen" or "id" not in item:
                out["seen"][str(n)] = item
            else:
                out["ids"][str(n)] = item["id"]
        return out

    def call(self, began, kind, messages, tool_calls=(), results=(), reply=None, ms=0,
             usage=None, screen=None, error="", plan=None, steer=None):
        if self.dead or began is None:
            return
        try:
            self.counts["calls"] += 1
            n = self.counts["calls"]
            usage = usage or {}
            tools = []
            for tool in tool_calls or ():
                function = tool.get("function") or {}
                try:
                    args = json.loads(function.get("arguments") or "{}")
                except ValueError:
                    args = function.get("arguments")
                tools.append({"name": function.get("name"), "args": args})
            screen = screen or {"tree": self.last_tree}
            record = Call(n=n, seq=began["seq"], at=began["at"], kind=kind,
                          messages=list(messages), tool_calls=list(tool_calls or ()), tools=tools,
                          results=list(results or ()), reply=reply, ms=ms,
                          tokens={"in": usage.get("prompt_tokens", 0),
                                  "out": usage.get("completion_tokens", 0)},
                          tree=screen.get("tree"), ids=screen.get("ids") or {},
                          seen=screen.get("seen") or {},
                          steps=[s for s, c in self.step_calls.items() if c == self.calling],
                          error=error, plan=list(plan or ()), steer=list(steer or ()))
            self._write(f"calls/{n:02d}.json", record)
            self._save_run()
        except Exception as failure:
            self._failed(failure)

    # Steps

    def begin_step(self, planned, item=None):
        if self.dead:
            return
        if self.step is not None:
            self.end_step()
        self.counts["steps"] += 1
        self.seq += 1
        planned = dict(planned or {})
        self.step = Step(n=self.counts["steps"], seq=self.seq, at=_now(), call=self.calling,
                         do=str(planned.get("do", "")), value=str(planned.get("value") or ""),
                         planned=planned, target=item, tree_before=self.last_tree)
        self.step_started = time.monotonic()
        self.step_calls[self.step.n] = self.calling

    def end_step(self, why=None, change=None, sentence="", outcome="", error="", shown=None):
        if self.dead or self.step is None:
            return
        step, self.step = self.step, None
        self.ended_step = step
        step.tree_after = self.last_tree if self.last_tree != step.tree_before else None
        step.change = change
        step.sentence = sentence
        step.outcome = outcome
        step.error = error or why or step.error
        step.ms = int((time.monotonic() - self.step_started) * 1000)
        if step.point is None and step.target and step.target.get("x") is not None:
            step.point = [step.target["x"], step.target["y"]]
        self._write(f"steps/{step.n:02d}.json", step)
        if shown is not None and self.run is not None:
            self.run.shown = list(shown)
        self._save_run()

    def add_to_step(self, ms=0, **fields):
        """Fields found after the step ended, and the time they took."""
        step = self.ended_step
        if self.dead or step is None:
            return
        for key, value in fields.items():
            setattr(step, key, value)
        step.ms += ms
        self._write(f"steps/{step.n:02d}.json", step)


OFF = Recorder()
