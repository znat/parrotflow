"""The review after an agent run: one model call reads the recording and
proposes memory files. Nothing is written until the user keeps a proposal.

The runner starts it in a thread once the run's `end` is sent. The digest is
built by code from the run folder: the request, the plan, each call's tools
in short form, each step's outcome, the failures and what came after, the
user's answers, the timings and the memory files the agent had. The model
answers with `Review`, strict. The timings in the report are code's.

The thread sends one line, never reads, and only while no run is being
served:

    runner  {"do": "review", "id": "<run folder>", "report": {"next_time": "..",
             "learned": [..], "time": [..], "went_wrong": [..]},
             "proposals": [{"file": "..", "content": "..", "why": "..", "exists": bool}]}
            | {"do": "review", "id": "..", "error": ".."}
    app     {"review": "<id>", "kept": ["<file>", ..], "via": "answered|closed|timeout|superseded"}

The app answers once, without a reply back. Kept files are written under
`<config>/memories/`. `review.json` in the run folder holds the review, the
proposals dropped by code and why, and the user's choice.
"""

import asyncio
import datetime
import glob
import json
import os
import re
import threading
import time
from typing import List

import pydantic_ai as pai

import agent as agenting
import skills as skilling
from planner import Strict

# Per attempt, tried once more. High reasoning over a digest takes far longer
# than a plan's 15 s.
TIMEOUT = 120
RETRIES = 1
MAX_PROPOSALS = 4
MAX_FILE = 2500
SCREEN_LINES = 5
LINE = 220
RESULT_LINES = 8
_RAN = re.compile(r"^(Ran \d+ of \d+:|\d+\. )")

PROMPT = """You review one run of an agent that works in a macOS app for the user. The agent sees the app's accessibility tree as `Role "name"` lines, and acts with tools: act (click, type, key…), use (plays a skill), look, ground, ask, done, stuck. A program does each step and reports what changed.

You get a digest of the run: the request, the plan, each model call with its tools and what came back, each step's outcome, the failures and what came after them, the user's answers, and the memory files the agent had for this app and for the people named.

Answer with a short report and proposals for memory files. The next run in this app reads the memory files first.

The report:
- next_time: what you would do next time, in one or two lines. Sending, inviting and posting are the user's to decide: never say to do them without asking.
- learned: one short line per thing this run taught. Empty when nothing.
- went_wrong: one short line per failed step and how it was fixed, or what blocked the run. Empty when nothing went wrong.
Say nothing about time: the program adds the timings.

A proposal is {file, content, why}:
- file: `<app folder>/<name>.md` for the app (the app folder is given in the digest), or `people/<first name>.md` for a person, lower case.
- content: the whole file, new or replacing the one that exists.
- why: one line for the user: what the file adds or changes.

Rules for proposals:
- Record the path that finally worked. Never record a detour, a retry, or a way around the program's own limits as the method.
- Be specific and actionable: where to click (for example "the left edge of Start date"), the exact keys and what to type (for example "⌘A, then type 25/09/26"), and what the screen shows when it worked.
- Record only what stays true next time: how the app works. Never a date, a time slot, who was free, or anything else true only of this run.
- Prefer updating an existing file over adding a new one. To update a file, give its whole new content under the same name, and keep what is still true.
- Facts about people come only from the user's answers: which email, how a name is spelled.
- Add a `steps:` block only when those exact gestures succeeded in this run, and each step has a check that a value in the tree can prove. Otherwise write prose. A file with `steps:` is a skill the agent calls with values: its `params` are exactly the `{param}`s its steps use, and its `goal` says what the steps do, so put other advice in a separate file.
- Each line of went_wrong that ends with a fix that worked is a lesson: propose it, unless a memory file already says it. So is each line of learned that the next run could act on.
- No proposal only when the run taught nothing the memory files do not already say.
- Keep files short: at most 15 lines of prose.

A file starts with front matter between `---` lines, then prose:

---
app: <bundle id>
goal: <what it does>
when: <what is on screen when it applies>
params: [<inputs>]
seen: <date> (worked | failed)
---

A person's file has `kind: person` and `seen:` instead of app, goal, when and params.

A `steps:` block goes in the front matter, after `seen:`. Each step is one gesture, then `|` and a check:
  - click <Role> "<name>" [at left|right] | focus "<name>"
  - type {<param>} | value "<name>" ~ "<glob>"
  - key <keys>
Gestures: `click <Role> "<name>" [at left|right]`, `type <text>`, `key <keys>`. Checks: `focus "<name>"`, `value "<name>" ~ "<glob>"`, `window ~ "<glob>"`, `appears "<glob>"`. `{param}` is filled from `params`. The role has no AX prefix: DateTimeArea, Button, TextField."""


class Proposal(Strict):
    file: str
    content: str
    why: str


class Review(Strict):
    next_time: str
    learned: List[str]
    went_wrong: List[str]
    proposals: List[Proposal]


REVIEWER = pai.Agent(None, instructions=PROMPT,
                     output_type=pai.ToolOutput(Review, name="review", strict=True),
                     retries={"output": 1})


# The digest


def _read(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def _all(folder, part):
    return [r for r in (_read(p) for p in sorted(glob.glob(os.path.join(folder, part, "*.json"))))
            if isinstance(r, dict)]


def _cut(text, count=LINE):
    text = " ".join(str(text or "").split())
    return text if len(text) <= count else text[:count - 1] + "…"


def _seconds(ms):
    return f"{ms / 1000:.1f} s"


class Recording:
    """A run folder, as read back."""

    def __init__(self, folder):
        self.folder = folder
        self.run = _read(os.path.join(folder, "run.json")) or {}
        self.calls = _all(folder, "calls")
        self.steps = _all(folder, "steps")
        self._trees = {}

    def tree(self, n):
        if not n:
            return None
        if n not in self._trees:
            self._trees[n] = _read(os.path.join(self.folder, "trees", f"{n:02d}.json"))
        return self._trees[n]

    def app(self):
        """(app name, bundle ID) from the first read, else from the request."""
        snapshot = (self.tree(1) or {}).get("snapshot") or {}
        return (snapshot.get("app") or self.run.get("app") or "",
                snapshot.get("bundle") or self.run.get("bundle") or "")

    def item(self, call, model_id):
        """What the model's `[ID]` named in `call`, as a short line."""
        key = str(model_id)
        if key in (call.get("seen") or {}):
            return f"seen \"{_cut(call['seen'][key].get('name'), 60)}\""
        wanted = (call.get("ids") or {}).get(key)
        snapshot = (self.tree(call.get("tree")) or {}).get("snapshot") or {}
        found = next((i for i in snapshot.get("items") or () if i.get("id") == wanted), None)
        if found is None:
            return f"[{model_id}]"
        return f"{str(found.get('role', '')).replace('AX', '')} \"{_cut(found.get('name'), 60)}\""

    def ms_total(self):
        try:
            began = datetime.datetime.fromisoformat(self.run["started"])
            ended = datetime.datetime.fromisoformat(self.run["ended"])
            return int((ended - began).total_seconds() * 1000)
        except (KeyError, TypeError, ValueError):
            return None


def _step_name(step):
    target = step.get("target") or {}
    name = target.get("name") or (step.get("planned") or {}).get("target") or ""
    said = step.get("do") or "step"
    if name:
        said += f" “{_cut(name, 50)}”"
    if step.get("value"):
        said += f" = “{_cut(step['value'], 40)}”"
    return said


def timings(recording):
    """Where the time went, from the recording's `ms`. Lines for the report."""
    calls, steps = recording.calls, recording.steps
    model = sum(int(c.get("ms") or 0) for c in calls)
    total = recording.ms_total()
    # How long the user took to answer is not recorded.
    asked = any(t.get("name") == "ask" for c in calls for t in c.get("tools") or ()) \
        or any(s.get("asked") for s in steps)
    lines = []
    if total is not None:
        lines.append(f"{_seconds(total)} in all: model {_seconds(model)}, "
                     f"{'harness and your answers' if asked else 'harness'} "
                     f"{_seconds(max(0, total - model))}.")
    if calls:
        slow = max(calls, key=lambda c: int(c.get("ms") or 0))
        lines.append(f"{len(calls)} model calls, the slowest {_seconds(int(slow.get('ms') or 0))} "
                     f"(call {slow.get('n')}).")
    if steps:
        took = sum(int(s.get("ms") or 0) for s in steps)
        slow = max(steps, key=lambda s: int(s.get("ms") or 0))
        lines.append(f"{len(steps)} steps, {_seconds(took)}; the slowest: {_step_name(slow)}, "
                     f"{_seconds(int(slow.get('ms') or 0))}.")
    return lines


def _tool_line(recording, call, tool):
    name, args = tool.get("name"), tool.get("args")
    if not isinstance(args, dict):
        return f"{name} (arguments not valid)"
    if name == "act":
        steps = []
        for step in args.get("steps") or ():
            said = f"{step.get('do')}"
            if step.get("id") is not None:
                said += " " + recording.item(call, step["id"])
            if step.get("value"):
                said += f" = \"{_cut(step['value'], 60)}\""
            steps.append(said)
        why = f"({_cut(args.get('why'), 80)}) " if args.get("why") else ""
        return f"act {why}" + "; ".join(steps)
    if name == "use":
        return f"use {args.get('skill')}({', '.join(map(str, args.get('values') or ()))})"
    if name == "ask":
        return f"ask \"{_cut(args.get('question'), 160)}\" [{' | '.join(args.get('options') or ())}]"
    if name in ("done", "stuck"):
        return f"{name}: {_cut(args.get('summary') or args.get('why'), 160)}"
    if name == "write_plan":
        items = [i.get("content", "") for i in args.get("items") or () if isinstance(i, dict)]
        return "write_plan: " + "; ".join(_cut(i, 60) for i in items)
    if name in ("look", "ground"):
        where = {k: v for k, v in args.items() if v is not None and k != "plan"}
        return f"{name} {_cut(json.dumps(where, ensure_ascii=False), 120)}"
    return name


def _result_lines(result):
    """A tool result without the screen: what ran and why it stopped."""
    text = str(result or "")
    for cut in ("\nChange:", "\nWindow:"):
        if cut in text:
            text = text.split(cut)[0]
    lines = [_cut(line) for line in text.splitlines() if line.strip()]
    return lines[:RESULT_LINES] + (["…"] if len(lines) > RESULT_LINES else [])


def _near(recording, step):
    """A few items of the screen around a failed step's target."""
    tree = recording.tree(step.get("tree_after") or step.get("tree_before"))
    snapshot = (tree or {}).get("snapshot") or {}
    point = step.get("point") or [(step.get("target") or {}).get(k) for k in ("x", "y")]
    if not point or None in point:
        return []
    items = [i for i in snapshot.get("items") or () if i.get("name") and i.get("kind") != "more"]
    items.sort(key=lambda i: (i.get("x", 0) - point[0]) ** 2 + (i.get("y", 0) - point[1]) ** 2)
    out = []
    for item in items[:SCREEN_LINES]:
        value = f" = \"{_cut(item['value'], 40)}\"" if item.get("value") else ""
        out.append(f"{str(item.get('role', '')).replace('AX', '')} \"{_cut(item['name'], 60)}\"{value}")
    return out


def memory_files(root, app_key, request):
    """[(file under memories/, text)] the agent had for this app and for the
    people the request names."""
    if not root:
        return []
    out = []
    for path in agenting.memory_paths(root, app_key, request):
        try:
            with open(path, encoding="utf-8") as handle:
                out.append((os.path.relpath(path, root), handle.read().strip()))
        except (OSError, UnicodeDecodeError):
            continue
    return out


def digest(recording, root):
    """(the digest as text, the app's memory folder, the timing lines)."""
    run = recording.run
    app, bundle = recording.app()
    folder = agenting.memory_folder(bundle or app)
    lines = [f"Request: {run.get('request', '')}",
             f"App: {app}" + (f" ({bundle})" if bundle else ""),
             f"App folder: {folder}",
             f"Ended: {run.get('end')} — {run.get('outcome') or run.get('said') or ''}"]
    plan = next((c["plan"] for c in reversed(recording.calls) if c.get("plan")), [])
    if plan:
        lines.append("Plan at the end:")
        lines += [f"- [{t.get('status')}] {t.get('content')}" for t in plan]

    steps_of = {}
    for step in recording.steps:
        steps_of.setdefault(step.get("call"), []).append(step)
    lines.append("Calls:")
    answers, failures = [], []
    for index, call in enumerate(recording.calls):
        tools = call.get("tools") or []
        said = "; ".join(_tool_line(recording, call, t) for t in tools) or "no tool"
        lines.append(f"{call.get('n')}. {said} — {call.get('ms', 0)} ms")
        if call.get("error"):
            lines.append(f"   error: {_cut(call['error'])}")
        for step in steps_of.get(call.get("n"), ()):
            outcome = step.get("error") or step.get("outcome") or step.get("sentence") or "ran"
            lines.append(f"   step {step.get('n')}: {_step_name(step)} — {_cut(outcome, 160)}"
                         + (f" [{step.get('ms')} ms]" if step.get("ms") else ""))
            for asked in step.get("asked") or ():
                answers.append(f"{asked.get('question')} — {asked.get('answer') or '(no answer)'}")
            if step.get("error"):
                after = recording.calls[index + 1] if index + 1 < len(recording.calls) else None
                then = "; ".join(_tool_line(recording, after, t) for t in after.get("tools") or ()) \
                    if after else "the run ended"
                failures.append((step, then))
        for tool, result in zip(tools, call.get("results") or ()):
            text = result.get("result") if isinstance(result, dict) else result
            name = tool.get("name")
            if name == "ask":
                answers.append(f"{tool.get('args', {}).get('question')} — {_cut(text)}")
            shown = _result_lines(text)
            if name == "act":
                # The steps above say what ran; the rest says why it stopped.
                shown = [line for line in shown if not _RAN.match(line)]
            elif name in ("look", "ground"):
                shown = shown[:3]
            elif name != "use":
                shown = []
            lines += [f"   > {line}" for line in shown]
    if failures:
        lines.append("Failures:")
        for step, then in failures:
            lines.append(f"- step {step.get('n')}: {_step_name(step)} — {_cut(step.get('error'), 160)}")
            near = _near(recording, step)
            if near:
                lines.append("  on screen near it: " + "; ".join(near))
            lines.append(f"  then: {_cut(then, 160)}")
    if answers:
        lines.append("The user's answers:")
        lines += [f"- {_cut(a)}" for a in answers]
    time_lines = timings(recording)
    if time_lines:
        lines.append("Time:")
        lines += [f"- {t}" for t in time_lines]
    files = memory_files(root, bundle or app, run.get("request", ""))
    lines.append("Memory files the agent had:" if files else "Memory files the agent had: none")
    for name, text in files:
        lines += [f"=== {name}", text]
    return "\n".join(lines), folder, time_lines


# The proposals


_APP_FILE = r"[a-z0-9][a-z0-9-]*\.md"
_PERSON_FILE = re.compile(r"^people/[a-zà-ÿ]+\.md$")
_CLICKED = re.compile(r'^\s*-\s*click\s+\w+\s+"([^"]+)"', re.M)


def succeeded(recording):
    """The names of the targets of the steps that did not fail."""
    return {(s.get("target") or {}).get("name") for s in recording.steps if not s.get("error")}


def problem(proposal, folder, done):
    """Why code drops a proposal, or None. `done`: the names of the targets
    this run acted on without an error."""
    file, content = proposal.file.strip(), proposal.content
    person = bool(_PERSON_FILE.match(file))
    if not person and not re.match(rf"^{re.escape(folder)}/{_APP_FILE}$", file):
        return f"not a memory file for this app or a person: {file!r}"
    head = content.split("---")
    if not content.lstrip().startswith("---") or len(head) < 3:
        return "no front matter"
    if len(content) > MAX_FILE:
        return f"too long: {len(content)} characters"
    if not re.search(r"^steps:", head[1], re.M):
        return None
    if person:
        return "a person's file has no steps"
    wrong = skilling.problems(content)
    if wrong:
        return f"steps: {wrong[0]}"
    missing = [n for n in _CLICKED.findall(head[1]) if n not in done]
    if missing:
        return f"steps: no click on \"{missing[0]}\" succeeded in this run"
    return None


# The review


class Pending:
    """One run's review: made in a thread, shown once, kept by the user."""

    def __init__(self, recorder, planner, root, log=print):
        self.recorder = recorder
        self.folder = recorder.folder
        self.id = os.path.basename(self.folder)
        self.planner = planner
        self.root = root
        self.log = log
        self.record = {"id": self.id, "at": datetime.datetime.now().astimezone().isoformat(
            timespec="seconds"), "shown": False, "kept": None, "via": None}
        self.proposals = []
        # The thread and the runner's main loop both save.
        self.lock = threading.Lock()

    def make(self):
        """The line for the app, or None when nobody waits for it. Never raises."""
        try:
            return self._make()
        except Exception as error:
            text = self.planner._clean(f"{type(error).__name__}: {error}")
            self.log(f"review: failed — {text}")
            self.record["error"] = text
            self.save()
            return {"do": "review", "id": self.id, "error": text}

    def _make(self):
        recording = Recording(self.folder)
        text, folder, time_lines = digest(recording, self.root)
        self.record["digest"] = text
        if self.record["via"]:
            # Answered before it was made: the panel was closed, or a new request came.
            self.save()
            return None
        began = self.recorder.begin_call(self.recorder.counts["calls"] + 1)
        messages = [{"role": "system", "content": PROMPT}, {"role": "user", "content": text}]
        started = time.monotonic()
        try:
            result, usage = asyncio.run(self._ask(text))
        except Exception as error:
            self.recorder.call(began, "review", messages, error=self.planner._clean(str(error)),
                               ms=int((time.monotonic() - started) * 1000))
            raise
        ms = int((time.monotonic() - started) * 1000)
        answer = result.output
        arguments = answer.model_dump_json()
        self.recorder.call(began, "review", messages,
                           tool_calls=[{"id": "review", "type": "function",
                                        "function": {"name": "review", "arguments": arguments}}],
                           reply=answer.model_dump(), ms=ms, usage=usage)
        done, kept, dropped = succeeded(recording), [], []
        for proposal in answer.proposals:
            why = problem(proposal, folder, done)
            if why is None and len(kept) >= MAX_PROPOSALS:
                why = f"more than {MAX_PROPOSALS} proposals"
            if why:
                dropped.append({"file": proposal.file, "why": why})
                self.log(f"review: dropped {proposal.file} — {why}")
                continue
            file = proposal.file.strip()
            kept.append({"file": file, "content": proposal.content.strip() + "\n",
                         "why": proposal.why.strip(),
                         "exists": bool(self.root) and os.path.exists(os.path.join(self.root, file))})
        self.proposals = kept
        report = {"next_time": answer.next_time.strip(),
                  "learned": [l.strip() for l in answer.learned if l.strip()],
                  "time": time_lines,
                  "went_wrong": [l.strip() for l in answer.went_wrong if l.strip()]}
        self.record.update(report=report, proposals=kept, dropped=dropped, ms=ms)
        self.save()
        self.log(f"review: {len(kept)} proposal(s), {len(dropped)} dropped, {ms} ms")
        return {"do": "review", "id": self.id, "report": report, "proposals": kept}

    async def _ask(self, text):
        client = self.planner.async_client(TIMEOUT, RETRIES)
        try:
            settings = {"openai_reasoning_effort": self.planner.review_reasoning} \
                if self.planner.review_reasoning else {}
            result = await REVIEWER.run(text, model=self.planner.responses_model(client),
                                        model_settings=settings)
        finally:
            await client.close()
        used = result.usage
        return result, {"prompt_tokens": used.input_tokens, "completion_tokens": used.output_tokens}

    def answered(self, kept, via):
        """The user's choice. Only a proposal that was shown can be written."""
        files = {p["file"]: p for p in self.proposals}
        saved = []
        for name in kept or ():
            proposal = files.get(name)
            if proposal is None or not self.root:
                continue
            path = os.path.join(self.root, name)
            try:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path + ".tmp", "w", encoding="utf-8") as handle:
                    handle.write(proposal["content"])
                os.replace(path + ".tmp", path)
                saved.append(name)
            except OSError as error:
                self.log(f"review: could not write {name} — {error}")
        self.record.update(kept=saved, via=via)
        self.save()
        if saved:
            self.log(f"review: kept {', '.join(saved)}")

    def save(self):
        with self.lock:
            text = json.dumps(self.record, ensure_ascii=False, indent=1)
            for secret in self.recorder.secrets:
                text = text.replace(secret, "[key]")
            path = os.path.join(self.folder, "review.json")
            try:
                with open(path + ".tmp", "w", encoding="utf-8") as handle:
                    handle.write(text)
                os.replace(path + ".tmp", path)
            except OSError as error:
                self.log(f"review: could not write review.json — {error}")


def start(pending, channel):
    """Makes the review in a thread and sends it when no run is being served."""
    def work():
        line = pending.make()
        if line is None:
            return
        with channel.lock:
            if channel.busy or channel.review is not pending:
                pending.record["shown"] = False
                pending.record["via"] = pending.record["via"] or "superseded"
                pending.save()
                return
            pending.record["shown"] = "error" not in line
            pending.save()
            channel.send(line)
    thread = threading.Thread(target=work, name="review", daemon=True)
    thread.start()
    return thread
