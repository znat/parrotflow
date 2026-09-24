"""The agent: a chat model with tools, when no recipe fits and
`actions.planner.loop` is `agent`.

The loop is Pydantic AI's: the calls to the model, the tool calls, their
argument checks, the retries and the limit on calls. `Planning` from
pydantic-ai-harness gives the model a task list. It writes one first, and
sees it at the end of every request. `done` is refused while a task is open.

The model gets the request and the screen as `[ID] Role "name"` lines. It
calls `act` with a batch of steps, `read`, `look`, `ask`, the plan tools,
`done` or `stuck`. Each step runs through `Loop._planned_step`, so the guards
are the planner's. A batch stops at the first surprise: a step failed,
changed nothing, or opened something the next step does not use. The model
then decides from what came back.

`ask` puts a question in the app's panel, next to what the last step acted
on. The answer comes back as the tool result. No answer ends the run.

Every read also reads the window's text from its pixels, when the app can.
A step's result names the text that appeared and is not in the tree, and
the controls that left the tree but are still on screen, with IDs `act` can
click at their centre. Text that appeared ends the batch, as a pop-up does.

`look` reads the text in a part of the screen from its pixels (Vision OCR in
the app), for what is outside the window or when the read had none. Its
lines get IDs too. Without that reading, a `type` into a lookup field that
changed nothing in the tree looks below the field once, and reports lines
that were not there before the typing.

`ground` finds a target in the pixels of the newest read, in a crop of at
most 600×400 points, and gives it a point ID that `act` clicks at
(`ground.py`). `actions.ground` picks TinyClick or the planner's model; off,
there is no `ground` tool.

Every request carries a picture of the area being worked in: a 512 px JPEG,
`detail: low`, of the list that opened, else around the last target, else,
on the first call, around the focused item or the gaze point. `_prepare`
drops the one before. No screenshot, no picture.

A surprise: a step failed, the same batch ran twice, `done` was refused, a
step's `expect` is not true after it (Jev, about 0.3 s, no model call), or a
step took a name or words out of the field it acted in (`loop.lost`). A
second surprise on the same plan task tells the model to `ask` the user; if its
next call is not `ask` or `read`, the runner asks instead: what surprised,
and "What should I do?".

No automatic `ground` call: an `act` step names its target by ID only, so a
step aimed at something without an ID carries no words to look for. The
prompt and the result of a step on an unknown ID point to `ground` instead.
"""

import dataclasses
import datetime
import json
import re
import time
from typing import List, Literal, Optional

import openai
import pydantic_ai as pai
from pydantic import ValidationError
from pydantic_ai.capabilities import ProcessHistory
from pydantic_ai_harness import Planning
from pydantic_ai_harness.planning import InMemoryPlanStore
from pydantic_ai_harness.planning import _capability as _plan_reminder
from pydantic_ai_harness.planning import _toolset as _plan_tools

import decider
import ground as grounding
import loop as looping
import planner as planning
from planner import Strict

MAX_CALLS = 50
MAX_OPTIONS = 4
SHOWN = 250
SECONDS = 240
Side = Literal["below", "above", "right", "left", "around"]
# Points. Below a field: its width plus a margin, and this far down.
MARGIN = 40
FAR = 400
MAX_SEEN = 40
# Around a list that opened, before the crop grows to 600×400.
LIST_MARGIN = 20
ANCHOR = {"below": "top", "above": "bottom", "right": "left", "left": "right"}
GROUNDER = grounding.Grounder.from_env()
_LOOKS_UP = re.compile(r"\b(attendees?|to|cc|bcc|search|invite|recipients?|participants?|people)\b")

SYSTEM = """You do a task in a macOS app for the user. You see the app's controls as `[ID] Role "name"` lines, and you act with tools. A program carries out each step on the user's real screen.

`act` takes `why`, what the steps are for in a few words, and steps, each {do, id, value, expect}:
- click: press the button, link, row, tab or checkbox `id`.
- pick: choose row `id` in a menu or list that is open.
- type: put a name, a search query, a subject or another short value into field `id`. `value` is the text. With `id` null it goes where the caret is.
- write: put the body of a message or comment into box `id`. `value` is the text. With `id` null it goes where the caret is.
- key: press a key or a shortcut. `value` in plus form: "cmd+shift+n", "return", "escape", "tab", "down". `id` is null.
- scroll: `id` is the list or pane, or null for where the user looks. `value` is "up" or "down".
`expect`: on a step whose outcome matters, what should be on screen after it, in a few words, such as "To holds Alex Moreau and Antonio Ruiz". Otherwise null.

Rules:
- IDs belong to one read. After each `act` or `read`, use only the IDs of the newest screen.
- A field's line shows what it holds after `=`. Check the values on the screen before you redo a step. A field that shows the value in another format (16:00 for 4 PM) is done.
- Prefer the screen lines. When something that should be there is not, such as the list after you type a name, `look` next to the item. Seen lines may be misread. They can be clicked, never typed into.
- Text marked "seen, not in the tree" is on screen but was read from pixels. Pick from it when it is a list that opened, such as people after you type a name.
- Controls "still on screen, no longer in the tree" mean a panel is open. Finish or close the panel (return or escape), or click the control to leave it.
- Put several steps in one `act` when you know what each one does. A step that opens a menu, a list or a dialog ends the batch: its rows get IDs in the next screen.
- "this", "here", "that one" mean the item the user is looking at. It is already chosen. Start from it.
- Type only words the user said. `write` only what the user asked to say. If they did not say it, click in the box and call `done`: the user will dictate it.
- Never select all in a message, a comment or a document, and never replace or delete text there.
- Never archive, leave or pay. Stop just before it and call `done`.
- `ask` the user a short question, with up to 4 short options, only when:
  - several items on screen could be what the user meant, such as two people with the same first name. The options are those items as the screen names them;
  - the next step would send, post, delete, start a call or invite people. Ask before that step, never after;
  - you cannot go on. Say what blocks you and ask what to do, instead of calling `stuck`.
- Do not ask anything else, and never ask the same thing twice. The answer is the tool result: act on it.
- Prefer the app's keyboard shortcut when it has one.
- Never invent a menu item or a label. Work out dates and times like "tomorrow at 10" from the date and time you are given, then find them on screen. When unsure, act one step at a time.
- A step after which nothing in the tree changed is not verified. Check the picture: it may have worked. If it did not, do not repeat it: try another way.
- Your first call is `write_plan`: the task as a few short steps. Keep the plan current: one step `in_progress`, a step `completed` once the screen shows it done, `cancelled` when it is not needed.
- Call `done` when the task is done, `stuck` when it cannot be done here and no question would help. `done` is refused while a plan step is open.
- The picture shows the area you are working in: check it for what the screen lines cannot say (which part of a field is selected, highlighted rows, chips, what covers what)."""
GROUNDING = ("When a target you need has no ID in the screen lines, such as a row in a list "
             "that opened, call `ground` with what it looks like before trying another way. It "
             "returns a point ID that `act` can click.")
NOTES = 2
SAME_POINT = 20
PLAN_TOOLS = {"write_plan", "read_plan", "add_task", "update_task_status", "update_task_statuses",
              "remove_task"}
OPEN = {"pending", "in_progress"}
ASK_NOW = ("Two steps surprised you on this task. Call `ask` now: say what happened in one "
           "sentence and ask how to proceed.")


class Step(Strict):
    do: planning.Do
    id: Optional[int] = None
    value: Optional[str] = None
    expect: Optional[str] = None


# A missing `why`, `summary` or option list is taken as empty: strict mode
# sends them, the test fakes do not.
class Act(Strict):
    """Do steps in order. IDs are those of the newest screen; every screen gives new IDs. Stops
    at the first step that fails, changes nothing, or opens something the next step does not
    target. Returns the steps that ran, what changed, and the screen with new IDs."""
    why: str = ""
    steps: List[Step]


class Read(Strict):
    """Read the screen again without acting. Returns it with new IDs."""


class Look(Strict):
    """Read the text in a part of the screen from its pixels, for what the screen lines miss.
    Give `id` and `side` to look next to an item, or x, y, w, h: the centre and size in
    points. Returns the lines seen, with IDs `act` can click. They may be misread."""
    id: Optional[int] = None
    side: Optional[Side] = None
    x: Optional[float] = None
    y: Optional[float] = None
    w: Optional[float] = None
    h: Optional[float] = None


class Ground(Strict):
    """Find a target that has no ID in the screen lines, such as a row of a list that opened,
    in the screen's pixels. `description`: the target as it looks, in a few words. Look next to
    item `id` (`side`, around when null), in x, y, w, h (centre and size in points), or, with
    neither, in the list or pop-up that opened last. After a picture was shown, image_x and
    image_y are the target's centre in its pixels. Returns a point ID `act` can click."""
    description: str
    id: Optional[int] = None
    side: Optional[Side] = None
    x: Optional[float] = None
    y: Optional[float] = None
    w: Optional[float] = None
    h: Optional[float] = None
    image_x: Optional[int] = None
    image_y: Optional[int] = None


class Ask(Strict):
    """Ask the user one short question, shown next to what the last step acted on. Offer at most
    4 short options; the user can also answer in their own words. Returns the answer. No
    answer ends the run."""
    question: str
    options: List[str] = []


class Done(Strict):
    """The task is done, or done up to where the user takes over."""
    summary: str = ""


class Stuck(Strict):
    """The task cannot be done from this screen."""
    why: str = ""


MODELS = {model.__name__.lower(): model for model in (Act, Read, Look, Ground, Ask, Done, Stuck)}


def _doc(model):
    return " ".join(model.__doc__.split())


def _render_plan(items):
    """The harness's checklist, with each task's ID. Without them the model
    guessed IDs for `update_task_statuses`: three calls lost per run, 09-24."""
    if not items:
        return "No plan yet."
    done = sum(1 for i in items if i.status.value == "completed")
    return "\n".join([f"{n}. {_plan_tools.status_icon(i.status)} [{i.id}] {i.content}"
                      for n, i in enumerate(items, 1)] + [f"({done}/{len(items)} completed)"])


_plan_tools.render_plan = _plan_reminder.render_plan = _render_plan


class PlanStore(InMemoryPlanStore):
    """The harness's store, which calls `changed` after every write of the
    plan tools. `now` reads it from a sync tool."""

    def __init__(self, changed):
        super().__init__()
        self.changed = changed

    def now(self):
        return list(self._items)

    async def set_items(self, items):
        await super().set_items(items)
        self.changed()

    async def add_item(self, item):
        added = await super().add_item(item)
        self.changed()
        return added

    async def update_item(self, item_id, **fields):
        updated = await super().update_item(item_id, **fields)
        self.changed()
        return updated

    async def remove_item(self, item_id):
        removed = await super().remove_item(item_id)
        self.changed()
        return removed


class Agent:
    """One run. It is also the run's deps: the tools reach the loop, the
    report, the screen and its IDs through it."""

    def __init__(self, loop):
        self.loop = loop
        self.planner = loop.planner
        self.report = None
        self.ids = {}
        self.steps = 0
        # What the last step acted on, and the pop-up rows it opened: where
        # a question is about.
        self.acted_on = None
        self.opened = []
        self.asked_when_stuck = False
        self.tried = {}
        # The task in progress at the last surprise, and how many it had.
        self.surprised = (None, 0)
        # The surprise the model was told to ask about.
        self.must_ask = None
        self.plan = PlanStore(lambda: self.loop.show(plan=self._plan()))
        # Plan item ID: what went wrong while it was in progress, newest last.
        self.notes = {}
        # A tool that ends the run sets it; the run stops after that turn.
        self.over = False
        self.ran = 0
        self.grounder = GROUNDER
        # What the last step aimed at, whether it ran or not.
        self.target = None
        # The picture last shown: its box in points and its size in pixels.
        self.shown = None
        # Where the picture in the request being sent was recorded.
        self.sent_image = None

    def run(self, report):
        lp = self.loop
        self.report = report
        if lp.execute:
            lp.call("watch")
        gaze = lp.request.get("gaze")
        self.aim = list(gaze) if gaze else [0, 0]
        self.snapshot = lp._read(self.aim, lp.app)
        lp.change, lp.fresh, lp.renamed = {}, set(), {}
        app, bundle = self.snapshot["app"], lp.request.get("bundle", "")
        now = datetime.datetime.now().astimezone()
        head = [f"Request: {lp.utterance}", f"App: {app}" + (f" ({bundle})" if bundle else ""),
                f"Now: {now:%A %d %B %Y, %H:%M} ({now.tzname()})"]
        notes = decider.notes_of(app, lp.log)
        if notes:
            head.append(f"How this app works: {notes}")
        head = "\n".join(head)
        self.prompt = f"{head}\n{self._screen(first=True)}"
        self.short = f"{head}\n(the screen is in the newest tool result)"
        if not self.planner.key:
            raise planning.Failure(f"No key for the planner — {self.planner.source}.")
        self.started = time.monotonic()
        clean = self.planner._clean
        try:
            output = self.planner.run(self._run(report))
        except pai.UsageLimitExceeded:
            report.stopped = f"Stopped after {MAX_CALLS} model calls"
            lp.log(f"agent: {report.stopped}")
            return
        except pai.ModelHTTPError as error:
            raise planning.Failure(clean(f"The planner answered {error.status_code}: "
                                         f"{str(error.body)[:200]}"))
        except pai.ModelAPIError as error:
            cause = error.__cause__ or error
            if isinstance(cause, openai.APITimeoutError):
                raise planning.Failure(f"The planner timed out after {planning.RETRIES + 1} tries.")
            raise planning.Failure(clean(str(cause) or type(cause).__name__))
        except pai.UnexpectedModelBehavior as error:
            raise planning.Failure(clean(f"The planner's answer could not be used: {error}"))
        self._end(output, report)

    def _plan(self):
        """The plan as the run panel and the recording read it."""
        return [{"content": i.content, "status": i.status.value, "notes": self.notes.get(i.id, [])}
                for i in self.plan.now()]

    def _note(self, text, task=None):
        """What went wrong, under the task in progress, or `task`."""
        if task is None:
            task = self._task()
        if task is None or not text:
            return
        notes = self.notes.setdefault(task, [])
        notes[:] = (notes + [decider.prefix(" ".join(str(text).split()), 160)])[-NOTES:]
        self.loop.show(plan=self._plan())

    async def _run(self, report):
        """The model's turns, one node at a time. The output, or None when
        the run stopped before one."""
        lp, recorder = self.loop, self.loop.recorder
        turn, calls = None, 0
        try:
            async with AGENT.iter(self.prompt, model=self.planner.agent_model, deps=self,
                                  model_settings=self._settings(),
                                  usage_limits=pai.UsageLimits(request_limit=MAX_CALLS)) as run:
                async for node in run:
                    if turn is not None and not isinstance(node, pai.CallToolsNode):
                        # The tools' results are the next request's parts; an
                        # output tool ends the run instead.
                        await self._record(turn, node.request.parts
                                           if isinstance(node, pai.ModelRequestNode) else None)
                        turn = None
                    if isinstance(node, pai.ModelRequestNode):
                        lp.show(now=True, plan=self._plan(), activity="thinking…")
                        if self.over:
                            return None
                        if self.steps >= lp.max_steps:
                            return self._over(report)
                        if time.monotonic() - self.started > SECONDS:
                            report.stopped = f"Stopped after {SECONDS} s"
                            lp.log(f"agent: {report.stopped}")
                            return None
                        calls += 1
                        self.ran = 0
                        self.planner.sent = None
                        self.sent_image = None
                        turn = {"n": calls, "screen": recorder.screen(self.snapshot, self.ids),
                                "began": recorder.begin_call(calls), "at": time.monotonic()}
                    elif isinstance(node, pai.CallToolsNode):
                        turn["ms"] = int((time.monotonic() - turn["at"]) * 1000)
                        turn["response"] = node.model_response
                        turn["sent"] = self._sent()
                        if not lp.execute and self._planned_only(turn, report):
                            await self._record(turn, [])
                            turn = None
                            return None
                return run.result.output if run.result else None
        except pai.UsageLimitExceeded:
            raise
        except Exception as error:
            if turn is not None and "response" in turn:
                await self._record(turn, [])
            elif turn is not None:
                recorder.call(turn["began"], "agent", self._sent(), screen=turn["screen"],
                              error=self.planner._clean(str(error)))
            raise

    def _settings(self):
        settings = {"parallel_tool_calls": False}
        if self.planner.reasoning:
            settings["openai_reasoning_effort"] = self.planner.reasoning
        return settings

    def _over(self, report):
        report.stopped = f"Stopped after {self.loop.max_steps} steps"
        self.loop.log(f"agent: {report.stopped}")
        return None

    def _end(self, output, report):
        lp = self.loop
        if isinstance(output, Done):
            box = lp.call("ready_for_words", app=self.snapshot["app"]).get("box")
            report.stopped = f"{box} is ready — dictate" if box else \
                "Done" if report.steps else "Nothing to do"
            lp.log(f"agent: done — {decider.prefix(output.summary, 200)}")
        elif isinstance(output, Stuck) and not report.stopped:
            report.stopped = f"Stuck — {decider.prefix(output.why, 120)}"
            lp.log(f"agent: {report.stopped}")

    def _planned_only(self, turn, report):
        """Plan only: says the first call that is not a plan tool, and ends
        the run. False while the model only plans."""
        lp = self.loop
        call = next((p for p in turn["response"].parts if isinstance(p, pai.ToolCallPart)
                     and p.tool_name not in PLAN_TOOLS), None)
        if call is None:
            return False
        lp.say(f"agent      call {turn['n']} · {self._said(call)}")
        args = self._args(call)
        for step in args.steps if isinstance(args, Act) else ():
            item = self.ids.get(step.id)
            lp.say(f"           {step.do} {step.value or ''} → "
                   + (decider.short(item, self.snapshot) if item else f"[{step.id}]"))
        lp.say("(planned only)")
        report.stopped = "(planned only)"
        return True

    async def _record(self, turn, parts):
        """One model call, its tool calls and their results: the app log,
        the trace and the run recording. `parts`: the results sent back, or
        None when an output tool ended the run."""
        lp = self.loop
        response = turn["response"]
        calls = [p for p in response.parts if isinstance(p, pai.ToolCallPart)]
        answered = {p.tool_call_id: p for p in parts or ()
                    if isinstance(p, (pai.ToolReturnPart, pai.RetryPromptPart))}
        results = []
        for call in calls:
            part = answered.get(call.tool_call_id)
            if isinstance(part, pai.RetryPromptPart):
                results.append({"tool": call.tool_name, "result": part.model_response()})
            elif part is not None:
                results.append({"tool": call.tool_name, "result": part.model_response_str()})
            elif parts is None and call.tool_name in ("done", "stuck"):
                results.append({"tool": call.tool_name, "result": "ok"})
        wire = [{"id": p.tool_call_id, "type": "function",
                 "function": {"name": p.tool_name, "arguments": p.args_as_json_str()}} for p in calls]
        usage = {"prompt_tokens": response.usage.input_tokens,
                 "completion_tokens": response.usage.output_tokens}
        plan = [{"content": i.content, "status": i.status.value} for i in await self.plan.get_items()]
        lp.log(f"agent: call {turn['n']} · {', '.join(self._said(c) for c in calls) or 'no tool'}"
               f" · {turn['ms']} ms, {usage['prompt_tokens']} tokens in")
        self._trace(turn["n"], turn["sent"], wire, results, turn["ms"], usage, plan)
        lp.recorder.call(turn["began"], "agent", turn["sent"], wire, results, ms=turn["ms"],
                         usage=usage, screen=turn["screen"], plan=plan)

    def _tool(self, name, args):
        """A screen tool, run for the model: its result, and the result cut
        for history in the metadata."""
        if self.over or self.ran:
            full = short = "Not run: one tool per turn."
        else:
            self.ran += 1
            forced = self.must_ask and name not in ("ask", "read") \
                and self._task() == self.surprised[0]
            full, short, ended = self._forced_ask() if forced else self._run_tool(name, args)
            self.over = self.over or ended
        metadata = {"short": short} if short != full else {}
        if name == "look":
            metadata["look"] = True
        return pai.ToolReturn(return_value=full, metadata=metadata)

    def _run_tool(self, name, args):
        """(result, the result cut for history, whether the run is over)."""
        lp = self.loop
        if name == "read":
            self.snapshot = lp._read(self.aim, self.snapshot["app"])
            return self._screen(), "Read the screen.", False
        if name == "ask" and args.question.strip():
            return self._ask(args, self.report)
        if name == "act" and args.steps:
            return self._repeated(args.steps, *self._act(args.steps, self.report)) + (False,)
        if name == "look":
            return self._look(args) + (False,)
        if name == "ground":
            return self._ground(args) + (False,)
        text = f"Not run: {name} needs other arguments."
        return text, text, False

    @staticmethod
    def _args(call):
        """The tool call's arguments as its model, or None."""
        model = MODELS.get(call.tool_name)
        if model is None:
            return None
        try:
            return model.model_validate_json(call.args_as_json_str() or "{}")
        except ValidationError:
            return None

    @classmethod
    def _said(cls, call):
        name = call.tool_name
        if name in PLAN_TOOLS:
            return name
        args = cls._args(call)
        if args is None:
            return f"{name} (arguments not valid)"
        if isinstance(args, Act):
            why = args.why.strip()
            return ("act " + (f"({decider.prefix(why, 80)}) " if why else "")
                    + "; ".join(f"{s.do} [{s.id}] {s.value or ''}".strip() for s in args.steps))
        if isinstance(args, Look):
            if args.id is not None:
                return f"look {args.side or 'below'} [{args.id}]"
            return f"look {args.x} {args.y} {args.w} {args.h}"
        if isinstance(args, Ground):
            said = f"ground \"{decider.prefix(args.description, 60)}\""
            if args.image_x is not None:
                return f"{said} at {args.image_x},{args.image_y} in the picture"
            if args.id is not None:
                return f"{said} {args.side or 'around'} [{args.id}]"
            if args.x is not None:
                return f"{said} at {args.x} {args.y} {args.w} {args.h}"
            return said
        said = getattr(args, "summary", "") or getattr(args, "why", "") \
            or getattr(args, "question", "")
        return f"{name} {decider.prefix(said, 80)}".strip()

    def _repeated(self, steps, text, short):
        """Seen 09-23 in Slack: the same two batches ran three times each,
        with the same result, until the calls ran out."""
        said = tuple((step.do, decider.label(self.ids[step.id]) if step.id in self.ids else None,
                      step.value) for step in steps)
        outcome = text.split("\nWindow:")[0]
        seen = self.tried.get(said)
        self.tried[said] = outcome
        if seen == outcome:
            note = ("This exact batch already ran and did the same thing. Do not repeat it: "
                    "try another way, or ask the user.")
            ask = self._surprise("this exact batch already ran and did the same thing",
                                 "This exact batch already ran and did the same thing")
            return f"{note}\n{text}" + (f"\n{ask}" if ask else ""), \
                f"{note} {short}" + (f" {ask}" if ask else "")
        return text, short

    def _act(self, steps, report):
        lp = self.loop
        for n, step in enumerate(steps, 1):
            if step.id is not None and step.id not in self.ids:
                text = f"Nothing ran: step {n} names ID {step.id}, not on the newest screen."
                if self.grounder.on:
                    text += " A target with no ID: call `ground` with what it looks like."
                self._note(text)
                return text, text
            if (self.ids[step.id] if step.id is not None else {}).get("kind") == "seen" \
                    and step.do not in ("click", "pick"):
                text = f"Nothing ran: step {n} would {step.do} into a seen line; seen lines can only be clicked."
                self._note(text)
                return text, text
        start, ran, stop, ask = self.snapshot, [], "", ""
        # (index in `ran`, the step as said, the field, lines seen below it after typing)
        listed = None
        # (index in `ran`, its change, the read after it): its seen lines get IDs.
        saw = None
        for n, step in enumerate(steps, 1):
            if self.steps >= lp.max_steps or time.monotonic() - self.started > SECONDS:
                stop = "the run's limit of steps or time"
                break
            item = self.ids.get(step.id) if step.id is not None else None
            self.target = item or self.target
            if item is not None and n > 1 and item["kind"] == "seen":
                stop = f"step {n} clicks a seen line, and the screen may have moved since the look"
                break
            if item is not None and n > 1:
                item = self._refind(item)
                if item is None:
                    stop = f"step {n}'s target is no longer on screen"
                    break
            value = (step.value or "").strip()
            if step.do == "key":
                value = planning.chord(value)
            expect = " ".join((step.expect or "").split())
            planned = {"do": step.do, "target": decider.label(item) if item else "",
                       "value": value, "expect": expect}
            self.steps += 1
            before = self.snapshot
            region = self._region(item, "below") if step.do == "type" and self._looks_up(item) \
                and self.snapshot.get("seen") is None else None
            was, error = self._seen(region) if region else (None, None)
            if error:
                was = None
            why, self.snapshot, self.aim, outcome = lp._planned_step(
                planned, self.snapshot, self.aim, report, item)
            said = f"{n}. {planning.describe_step(dict(planned, expect=''))}"
            if why and why.startswith(looping.REDIRECTED):
                self._note(why)
                ran.append(f"{said} — {why}")
                stop = f"the user answered step {n}'s question with other words"
                break
            if why:
                ran.append(f"{said} — failed: {why}")
                stop = f"step {n} failed"
                ask = self._surprise(f"\"{planning.describe_step(planned)}\" failed", why)
                break
            ran.append(f"{said} — {outcome}")
            self.acted_on = item
            self.opened = [i for i in looping.appeared(before, self.snapshot) if i.get("in")]
            if lp.change.get("seen") or lp.change.get("still"):
                saw = (len(ran) - 1, lp.change, self.snapshot)
            surprise = self._check(step.do, expect, item, before, outcome)
            if surprise:
                ran[-1] += f" — {surprise}"
                stop = f"step {n} did not go as expected"
                ask = self._surprise(surprise)
                break
            if was is not None and outcome.endswith(looping.UNCHANGED):
                seen = {self._norm(line["text"]) for line in was}
                new = [line for line in self._seen(region)[0]
                       if self._norm(line["text"]) not in seen]
                if new:
                    listed = (len(ran) - 1, said, item, new)
                    stop = f"a list opened after step {n}, seen on screen only"
                    break
            following = steps[n] if n < len(steps) else None
            if outcome.endswith(looping.UNCHANGED) and step.do not in ("type", "write"):
                self._note(f"{planning.describe_step(planned)} changed nothing")
                stop = f"step {n} changed nothing"
                break
            if following and lp.change.get("appeared") \
                    and not (self.ids.get(following.id) or {}).get("in"):
                stop = f"something opened after step {n}, and step {n + 1} does not use it"
                break
            if following and lp.change.get("seen") \
                    and not self._in_blocks(self.ids.get(following.id), lp.change["seen"]):
                stop = f"text appeared after step {n}, and step {n + 1} does not use it"
                break
        screen = self._screen()
        if saw:
            at, change, after = saw
            shown = looping.sentence(change)
            blocks = [line for block in change.get("seen", ()) for line in block["lines"]] \
                if after is self.snapshot else []
            # Later steps in the batch may have run: a control still on screen
            # keeps its place, and the next read will not report it again.
            still = [line for line in change.get("still", ())
                     if after is self.snapshot or looping.still_there(line, self.snapshot)]
            lines = blocks[:looping.SEEN_SHOWN] + still[:looping.SEEN_SHOWN]
            for (n, item), line in zip(self._number(lines), lines):
                line["id"] = n
            if blocks:
                self.opened = [self.ids[line["id"]] for line in blocks if "id" in line]
            ran[at] = ran[at].replace(shown, looping.sentence(change))
        if listed:
            at, said, field, new = listed
            numbered = self._number(new)
            self.opened = [line for _, line in numbered]
            ran[at] = (f"{said} — nothing changed in the tree, but a list opened "
                       f"near \"{decider.label(field)}\" (seen, not from the tree): "
                       + ", ".join(f"[{n}] \"{decider.prefix(line['name'], 60)}\""
                                   for n, line in numbered))
        short = "\n".join([f"Ran {len(ran)} of {len(steps)}:"] + ran
                          + ([f"Stopped: {stop}"] if stop else []))
        change = {k: v for k, v in looping.changes(start, self.snapshot).items()
                  if k not in ("seen", "still")}
        change = json.dumps(change, ensure_ascii=False)
        ask = f"\n{ask}" if ask else ""
        return f"{short}\nChange: {change}\n{screen}{ask}", short + ask

    def _check(self, do, expect, item, before, outcome):
        """What went wrong in a step that ran, or "": a name or words gone
        from the field it acted in, or its `expect` not true now."""
        lp, said, record = self.loop, [], {}
        gone = looping.lost(item, before, self.snapshot) if item and do != "key" else []
        if gone:
            record["lost"] = ", ".join(f"\"{g}\"" for g in gone)
            said.append(f"this step removed {record['lost']} from \"{decider.label(item)}\"")
        # The tree did not change, so Jev can only say no.
        if expect and not outcome.endswith(looping.UNCHANGED):
            began = time.monotonic()
            try:
                p = decider.true_now(lp.jev, expect, self.snapshot, outcome)
            except decider.Failure as error:
                p = None
                lp.log(f"agent: could not check “{expect}” — {error}")
            ms = int((time.monotonic() - began) * 1000)
            record.update(expect=expect, expect_p=p, expect_ms=ms)
            if p is not None:
                lp.log(f"agent: expected “{expect}” — {p:.2f}, {ms} ms")
            if p is not None and p < 0.5:
                said.append(f"expected \"{expect}\", not what happened")
        if record:
            lp.recorder.add_to_step(record.get("expect_ms", 0), **record)
        return "; ".join(said)

    def _task(self):
        return next((i.id for i in self.plan.now() if i.status.value == "in_progress"), None)

    def _surprise(self, why, note=None):
        """Something did not go as the model expected. A second surprise on
        the same task: the instruction to ask the user, else ""."""
        if note is not False:
            self._note(note or why)
        task = self._task()
        if task is None:
            return ""
        count = self.surprised[1] + 1 if self.surprised[0] == task else 1
        self.surprised = (task, count)
        if count < 2:
            return ""
        self.must_ask = why
        return ASK_NOW

    def _forced_ask(self):
        """The model was told to ask and did something else: the runner asks."""
        line = decider.prefix(self.must_ask, 200)
        text, short, ends = self._ask(
            Ask(question=f"{line[:1].upper()}{line[1:]}. What should I do?",
                options=["Stop"]), self.report)
        if text == "The user answered: Stop":
            self.report.stopped = "Stopped — you said stop"
            self.loop.log(f"agent: {self.report.stopped}")
            ends = True
        said = "Not run: you were told to ask the user first, so the runner asked. "
        return said + text, said + short, ends

    def _look(self, args):
        """The `look` tool. (result, the result cut for history)."""
        if args.id is not None:
            item = self.ids.get(args.id)
            if item is None:
                text = f"Not run: ID {args.id} is not on the newest screen."
                return text, text
            side = args.side or "below"
            region = self._region(item, side)
            where = f"{side} [{args.id}] {planning._line(item)}"
        else:
            region = {"x": args.x, "y": args.y, "w": args.w, "h": args.h}
            if None in region.values() or region["w"] <= 0 or region["h"] <= 0:
                text = "Not run: look needs an `id`, or x, y, w and h."
                return text, text
            where = "at {x:.0f},{y:.0f}, {w:.0f}×{h:.0f}".format(**region)
        lines, error = self._seen(region)
        if error:
            text = f"Could not look: {error}"
            return text, text
        if not lines:
            text = f"Looked {where}: no text seen."
            return text, text
        numbered = self._number(lines)
        full = "\n".join([f"Looked {where}. Seen, may misread; click only:"]
                         + [f"[{n}] \"{line['name']}\"" for n, line in numbered])
        return full, f"Looked {where}: {len(numbered)} lines."

    def _seen(self, region):
        """The text lines in a region of the screen, top to bottom: (lines,
        None) or ([], why not)."""
        reply = self.loop.call("look", **{k: round(v) for k, v in region.items()})
        if reply.get("error"):
            if not getattr(self, "look_failed", None):
                self.look_failed = reply["error"]
                self.loop.log(f"agent: could not look — {reply['error']}")
            return [], str(reply["error"])
        lines = [line for line in reply.get("lines") or ()
                 if isinstance(line, dict) and str(line.get("text") or "").strip()]
        lines.sort(key=lambda line: (line.get("y", 0) // 10, line.get("x", 0)))
        return lines[:MAX_SEEN], None

    def _number(self, lines):
        """IDs for seen lines, after the screen's, as items `act` can click."""
        first = (max(self.ids, default=0) // 100 + 1) * 100 + 1
        numbered = []
        for n, line in enumerate(lines, first):
            item = {"kind": "seen", "role": "Seen", "name": " ".join(str(line["text"]).split()),
                    "value": "", "state": [], "p": line.get("p"),
                    **{k: float(line.get(k) or 0) for k in ("x", "y", "w", "h")}}
            self.ids[n] = item
            numbered.append((n, item))
        return numbered

    def _region(self, item, side):
        """{x, y, w, h}, centre and size, next to `item`. Clamped to the
        screen, not the window: Outlook draws its suggestions outside it."""
        left, top = item["x"] - item["w"] / 2, item["y"] - item["h"] / 2
        right, bottom = left + item["w"], top + item["h"]
        wide = max(right + MARGIN, left - MARGIN + FAR)
        box = {"below": (left - MARGIN, bottom, wide, bottom + FAR),
               "above": (left - MARGIN, top - FAR, wide, top),
               "right": (right, item["y"] - FAR / 2, right + FAR, item["y"] + FAR / 2),
               "left": (left - FAR, item["y"] - FAR / 2, left, item["y"] + FAR / 2),
               "around": (left - FAR / 2, top - FAR / 2, right + FAR / 2, bottom + FAR / 2)}[side]
        screen = self.loop.request.get("screen") or {}
        if screen.get("w") and screen.get("h") and 0 <= item["x"] <= screen["w"] \
                and 0 <= item["y"] <= screen["h"]:
            bounds = (0, 0, screen["w"], screen["h"])
        else:
            frame = self.snapshot.get("frame") or {}
            bounds = (frame.get("x", box[0]), frame.get("y", box[1]),
                      frame.get("x", box[0]) + frame.get("w", box[2] - box[0]),
                      frame.get("y", box[1]) + frame.get("h", box[3] - box[1]))
        x0, y0 = max(box[0], bounds[0]), max(box[1], bounds[1])
        x1, y1 = min(box[2], bounds[2]), min(box[3], bounds[3])
        x1, y1 = max(x1, x0 + 1), max(y1, y0 + 1)
        return {"x": (x0 + x1) / 2, "y": (y0 + y1) / 2, "w": x1 - x0, "h": y1 - y0}

    @staticmethod
    def _in_blocks(item, blocks):
        """Whether `item` is a seen line of one of `blocks`."""
        return bool(item) and item["kind"] == "seen" and any(
            item["name"] == line["text"] and abs(item["x"] - line["x"]) <= looping.SAME_PLACE
            and abs(item["y"] - line["y"]) <= looping.SAME_PLACE
            for block in blocks for line in block["lines"])

    @staticmethod
    def _looks_up(item):
        return bool(item) and item["kind"] == "text" and item["role"] != "AXTextArea" and (
            item.get("lookup") or item["role"] in ("AXComboBox", "AXSearchField")
            or _LOOKS_UP.search(item["name"].lower()) is not None)

    @staticmethod
    def _norm(text):
        return " ".join(str(text).lower().split())

    def _ground(self, args):
        """The `ground` tool. (result, the result cut for history)."""
        text = " ".join(args.description.split())
        if not text:
            said = "Not run: ground needs a description."
            return said, said
        if args.image_x is not None and args.image_y is not None:
            return self._from_picture(text, args.image_x, args.image_y)
        area = self._ground_area(args)
        if isinstance(area, str):
            return area, area
        region, anchor, where = area
        shot = self.snapshot.get("shot") or {}
        box = grounding.crop_box(region, shot["frame"], anchor) if shot.get("file") else None
        if box is None:
            said = ("Could not ground: that part of the screen is not in the window's picture."
                    if shot.get("file") else "Could not ground: this read has no picture.")
            return said, said
        found = self.grounder.point(shot, box, text, self.planner, self.loop.log)
        self._record_ground(found, text, box, shot)
        if found.get("error"):
            said = f"Could not ground: {found['error']}"
            return said, said
        if found["point"] is None:
            said = (f"Not found: no \"{decider.prefix(text, 60)}\" {where}. Look elsewhere, "
                    "scroll, or try another way.")
            return said, said
        return self._pointed(text, found["point"], found["method"], "from pixels")

    def _ground_area(self, args):
        """(region, anchor, where) for `ground`, or why not."""
        if args.id is not None:
            item = self.ids.get(args.id)
            if item is None:
                return f"Not run: ID {args.id} is not on the newest screen."
            side = args.side or "around"
            return self._region(item, side), ANCHOR.get(side, "centre"), f"{side} [{args.id}]"
        region = {"x": args.x, "y": args.y, "w": args.w, "h": args.h}
        if None not in region.values():
            if region["w"] <= 0 or region["h"] <= 0:
                return "Not run: w and h must be more than 0."
            return region, "centre", "at {x:.0f},{y:.0f}".format(**region)
        opened = self._opened_region()
        if opened is None:
            return "Not run: ground needs an `id`, or x, y, w and h: no list has opened."
        return opened, "centre", "in the list that opened"

    def _opened_region(self):
        """Centre and size of what the last step opened, with a margin."""
        items = [i for i in self.opened if i.get("w") and i.get("h")]
        if not items:
            return None
        x0 = min(i["x"] - i["w"] / 2 for i in items) - LIST_MARGIN
        y0 = min(i["y"] - i["h"] / 2 for i in items) - LIST_MARGIN
        x1 = max(i["x"] + i["w"] / 2 for i in items) + LIST_MARGIN
        y1 = max(i["y"] + i["h"] / 2 for i in items) + LIST_MARGIN
        return {"x": (x0 + x1) / 2, "y": (y0 + y1) / 2, "w": x1 - x0, "h": y1 - y0}

    def _from_picture(self, text, x, y):
        """A point the model read off the picture it was shown."""
        if self.shown is None:
            said = "Not run: no picture was shown; give an `id` or a region instead."
            return said, said
        box, (w, h) = self.shown["box"], self.shown["size"]
        if not (0 <= x <= w and 0 <= y <= h):
            said = f"Not run: {x},{y} is outside the picture, which is {w}×{h} pixels."
            return said, said
        point = [round(box[0] + x / w * (box[2] - box[0]), 1),
                 round(box[1] + y / h * (box[3] - box[1]), 1)]
        self.loop.recorder.ground({"method": "image", "description": text, "point": point,
                                   "region": self._centred(box)})
        return self._pointed(text, point, "image", "from the picture")

    def _pointed(self, text, point, method, source):
        had = set(self.ids)
        n = self._point(text, point, method)
        if n in had:
            said = (f"[{n}] already points there. Click it with `act`, or try another way: "
                    "asking again gives the same point.")
        else:
            said = f"[{n}] point for \"{decider.prefix(text, 60)}\" ({source})"
        return said, said

    def _point(self, text, point, method):
        """A point ID `act` can click, as a seen line is clicked. The ID it
        already has when the same point was asked for before."""
        # Seen 09-24 in Notion: nine grounds in a row within 8 px of each other.
        for n, item in self.ids.items():
            if item.get("role") == "Point" and abs(item["x"] - point[0]) <= SAME_POINT \
                    and abs(item["y"] - point[1]) <= SAME_POINT:
                return n
        n = (max(self.ids, default=0) // 100 + 1) * 100 + 1
        self.ids[n] = {"kind": "seen", "role": "Point", "name": text, "value": "", "state": [],
                       "p": None, "x": point[0], "y": point[1], "w": 0.0, "h": 0.0,
                       "ground": method}
        return n

    @staticmethod
    def _centred(box):
        return {"x": (box[0] + box[2]) / 2, "y": (box[1] + box[3]) / 2,
                "w": box[2] - box[0], "h": box[3] - box[1]}

    def _record_ground(self, found, text, box, shot, why=""):
        return self.loop.recorder.ground({
            "method": found["method"], "description": text, "why": why,
            "region": self._centred(box), "crop": found.get("crop"), "shot": shot.get("file", ""),
            "point": found.get("point"), "raw": found.get("raw"), "ms": found.get("ms", 0),
            "tokens": found.get("tokens"), "error": found.get("error") or ""},
            found.get("image"))

    def _area(self):
        """(text, JPEG, what it shows) for the area being worked in, or None
        without a screenshot."""
        shot = self.snapshot.get("shot") or {}
        if not shot.get("file"):
            return None
        region, what = self._opened_region(), "the list that opened"
        if region is None:
            item = self.target and (self._refind(self.target) or self.target)
            item = item or next((i for i in self.snapshot["items"]
                                 if "focused" in (i.get("state") or ())), None)
            if item is not None:
                what = f"\"{decider.label(item)}\""
            elif any(self.aim):
                item = {"x": self.aim[0], "y": self.aim[1], "w": 0, "h": 0}
                what = "where the user looks"
            else:
                return None
            region = self._region(item, "around")
        box = grounding.crop_box(region, shot["frame"])
        if box is None:
            return None
        crop = grounding.pixels(box, shot)
        try:
            image, size = grounding.jpeg(shot["file"], crop)
        except (ImportError, OSError) as error:
            self.loop.log(f"agent: no picture — {error}")
            return None
        text = f"The picture: the screen around {what}, {size[0]}×{size[1]} pixels."
        if self.grounder.on:
            text += (" For a target in it with no ID, call `ground` with its description, or "
                     "with image_x and image_y, its centre in this picture's pixels.")
        return text, image, {"box": box, "size": size, "crop": crop,
                             "shot": shot.get("file", ""), "what": what}

    def _sent(self):
        """The request as recorded: the instructions as a system message, then
        the Responses input. A picture is its file in the run folder, not its
        bytes."""
        body = self.planner.sent or {}
        head = [{"role": "system", "content": body["instructions"]}] \
            if body.get("instructions") else []

        def clean(node):
            if isinstance(node, list):
                return [clean(n) for n in node]
            if not isinstance(node, dict):
                return node
            if node.get("type") == "input_image":
                return dict(node, image_url=f"[picture: {self.sent_image or 'not kept'}]")
            return {k: clean(v) for k, v in node.items()}
        return clean(head + list(body.get("input") or []))

    def _ask(self, args, report):
        lp = self.loop
        self.must_ask, self.surprised = None, (None, 0)
        options = [o.strip() for o in args.options if o.strip()]
        asked = time.monotonic()
        answer, via = lp.ask(args.question.strip(), options[:MAX_OPTIONS], self._near())
        # The user's time is not the run's.
        self.started += time.monotonic() - asked
        if answer is None:
            report.stopped = "Stopped — no answer"
            lp.log(f"agent: {report.stopped} ({via})")
            return "No answer: the run stops.", "No answer.", True
        text = f"The user answered: {answer}"
        return text, text, False

    def _near(self):
        """The frame the question is about: the item the last step acted on,
        as it is now, and the pop-up rows that step opened."""
        item = self.acted_on and (self._refind(self.acted_on) or self.acted_on)
        return looping.frame(item, *self.opened)

    def _refind(self, item):
        """The same control in the newest read: IDs change with every read."""
        same = [i for i in self.snapshot["items"] if (i["kind"], i["role"], i["name"])
                == (item["kind"], item["role"], item["name"])]
        return min(same, key=lambda i: (i["x"] - item["x"]) ** 2 + (i["y"] - item["y"]) ** 2) \
            if same else None

    def _screen(self, first=False):
        """The newest read as numbered lines: every item, up to SHOWN. The
        gaze orders the first screen only; after a step it says nothing."""
        snapshot = self.snapshot
        # The filter Jev needs cut Teams' "Create a new event." (52 of 111
        # shown), and the model clicked "Start an instant Teams meeting".
        offers = [i for i in snapshot["items"] if i["kind"] != "more"
                  and (i["name"] or i["kind"] == "text")]
        if not first:
            offers.sort(key=lambda i: (i["y"] // 20, i["x"]))
        offers = offers[:SHOWN]
        # Same name, same kind: one line, and the first in reading order.
        # Teams draws "Create a new event." twice.
        earliest, count = {}, {}
        for item in offers:
            name = (item["kind"], tuple(decider._words(item["name"])))
            count[name] = count.get(name, 0) + 1
            if not item["name"] or name not in earliest \
                    or (item["y"], item["x"]) < (earliest[name]["y"], earliest[name]["x"]):
                earliest[name] = item
        offers = [i for i in offers if not i["name"]
                  or earliest[(i["kind"], tuple(decider._words(i["name"])))] is i]
        self.twins = {id(i): count[(i["kind"], tuple(decider._words(i["name"])))]
                      for i in offers if i["name"]}
        self.loop.among = offers
        self.ids = {n: item for n, item in enumerate(offers, 1)}
        lines = [f"Window: \"{snapshot['window']}\""]
        if first:
            looking = planning.gaze_item(snapshot, offers)
            at = next((n for n, i in self.ids.items() if i is looking), None)
            lines += [f"Looking at: [{at}] {planning._line(looking)}" if at else
                      "Looking at: nothing in particular",
                      "On screen, nearest the user's gaze first:"]
        else:
            lines.append("On screen, top to bottom. New IDs; earlier ones no longer work:")
        lines += [f"[{n}] {planning._line(item)}"
                  + (f" ×{self.twins[id(item)]}" if self.twins.get(id(item), 1) > 1 else "")
                  for n, item in self.ids.items()]
        return "\n".join(lines)

    def _trace(self, call, sent, calls, results, ms, usage, plan):
        line = json.dumps({"at": datetime.datetime.now().isoformat(timespec="seconds"),
                           "call": call, "request": self.loop.utterance, "messages": sent,
                           "tool_calls": calls, "results": results, "ms": ms,
                           "tokens": {"in": usage.get("prompt_tokens", 0),
                                      "out": usage.get("completion_tokens", 0)},
                           "plan": plan},
                          ensure_ascii=False)
        try:
            with open(self.planner.trace, "a", encoding="utf-8") as handle:
                handle.write(self.planner._clean(line) + "\n")
        except OSError as error:
            self.loop.log(f"agent: could not write the trace — {error}")


def _cut(ctx: pai.RunContext[Agent], messages):
    """Only the newest screen in full, and the looks after it; earlier ones
    cut to what ran. The plan reminder is added after this, so it is never
    cut."""
    deps = ctx.deps

    def short(part):
        if isinstance(part, pai.UserPromptPart) and part.content == deps.prompt:
            return deps.short
        if isinstance(part, pai.ToolReturnPart) and isinstance(part.metadata, dict):
            return part.metadata.get("short")
        return None

    def look(part):
        return isinstance(part, pai.ToolReturnPart) and part.metadata.get("look")

    newest = max(((i, j) for i, m in enumerate(messages) if isinstance(m, pai.ModelRequest)
                  for j, p in enumerate(m.parts) if short(p) is not None and not look(p)),
                 default=None)
    if newest is None:
        return messages
    cut = []
    for i, message in enumerate(messages):
        if isinstance(message, pai.ModelRequest) and i <= newest[0]:
            message = dataclasses.replace(message, parts=[
                dataclasses.replace(p, content=short(p))
                if short(p) is not None and (i, j) < newest else p
                for j, p in enumerate(message.parts)])
        cut.append(message)
    return cut


def _is_picture(part):
    return isinstance(part, pai.UserPromptPart) and not isinstance(part.content, str) \
        and any(isinstance(c, pai.BinaryContent) for c in part.content)


def _picture(ctx: pai.RunContext[Agent], messages):
    """The picture of the working area, on the request about to be sent.
    The one before is dropped: one picture per request."""
    deps = ctx.deps
    messages = [dataclasses.replace(m, parts=[p for p in m.parts if not _is_picture(p)])
                if isinstance(m, pai.ModelRequest) and any(_is_picture(p) for p in m.parts)
                else m for m in messages]
    area = deps._area() if isinstance(messages[-1], pai.ModelRequest) else None
    if area is None:
        return messages
    text, image, shown = area
    deps.shown = shown
    deps.sent_image = deps.loop.recorder.ground({
        "method": "image", "description": shown["what"],
        "region": Agent._centred(shown["box"]), "crop": shown["crop"], "shot": shown["shot"]},
        image)
    part = pai.UserPromptPart([text, pai.BinaryContent(image, media_type="image/jpeg",
                                                       vendor_metadata={"detail": "low"})])
    messages[-1] = dataclasses.replace(messages[-1], parts=[*messages[-1].parts, part])
    return messages


def _prepare(ctx: pai.RunContext[Agent], messages):
    return _picture(ctx, _cut(ctx, messages))


def _grounding(ctx: pai.RunContext[Agent]):
    return GROUNDING if ctx.deps.grounder.on else ""


async def _ground_on(ctx: pai.RunContext[Agent], tool):
    return tool if ctx.deps.grounder.on else None


async def _check_end(ctx: pai.RunContext[Agent], output):
    """`done` with a plan task open is refused. `stuck` asks the user once
    first; an answer other than Stop goes back to the model."""
    deps = ctx.deps
    if isinstance(output, Done):
        still = [i for i in await deps.plan.get_items() if i.status.value in OPEN]
        if still:
            deps._note("`done` refused: this task is still open", task=still[0].id)
            ask = deps._surprise("`done` was refused", False)
            raise pai.ModelRetry(f"Not done: '{still[0].content}' is still open. Finish it, "
                                 "or cancel it with a reason." + (f" {ask}" if ask else ""))
    elif deps.loop.execute and not deps.asked_when_stuck:
        # Seen 09-23: stuck after leaving the event form by mistake. The
        # user could have said "go back to the form".
        deps.asked_when_stuck = True
        why = output.why.strip()
        text, _, ends = deps._ask(
            Ask(question=f"{decider.prefix(why, 200)} What should I do?", options=["Stop"]),
            deps.report)
        if not ends and text != "The user answered: Stop":
            raise pai.ModelRetry(text)
        deps.report.stopped = f"Stuck — {decider.prefix(why, 120)}"
        deps.loop.log(f"agent: {deps.report.stopped}")
    return output


def _tool(name, model, prepare=None):
    def run(ctx: pai.RunContext[Agent], args):
        return ctx.deps._tool(name, args)
    run.__annotations__["args"] = model
    return pai.Tool(run, takes_ctx=True, name=name, description=_doc(model), strict=True,
                    sequential=True, prepare=prepare)


def _read(ctx: pai.RunContext[Agent]):
    return ctx.deps._tool("read", None)


# Retries: a wrong argument or a refused `done` goes back to the model as
# often as the call limit allows, as before the port.
AGENT = pai.Agent(
    None, deps_type=Agent, instructions=[SYSTEM, _grounding],
    tools=[_tool("act", Act),
           pai.Tool(_read, takes_ctx=True, name="read", description=_doc(Read), strict=True,
                    sequential=True),
           _tool("look", Look), _tool("ground", Ground, _ground_on), _tool("ask", Ask)],
    output_type=[pai.ToolOutput(Done, name="done", strict=True),
                 pai.ToolOutput(Stuck, name="stuck", strict=True)],
    retries={"tools": MAX_CALLS, "output": MAX_CALLS},
    capabilities=[ProcessHistory(_prepare),
                  # Its guidance says "for multi-step work"; SYSTEM asks for the plan first.
                  Planning(guidance="", store_resolver=lambda ctx: ctx.deps.plan)])
AGENT.output_validator(_check_end)
