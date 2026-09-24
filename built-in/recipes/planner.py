"""The planner: a remote chat model that knows how apps work.

Jev picks well among a few things (0.95-0.99) and badly when asked "what now"
over a whole window (0.32-0.52). The planner answers "what now" as a list of
steps, each naming its target in words. Jev then finds each target on screen
with a narrow question. The planner never sees the screen as pixels: it gets
the request, the window title and the names of the controls near the gaze.

Configured through the runner's environment, like Jev: PARROTFLOW_PLANNER_MODEL,
PARROTFLOW_PLANNER_URL, PARROTFLOW_PLANNER_KEY, PARROTFLOW_PLANNER_KEY_SOURCE,
PARROTFLOW_PLANNER_REASONING, PARROTFLOW_PLANNER_TIMEOUT. No model, no planner.
The call goes through the `openai` package. Its base URL is the endpoint
without `/chat/completions`. Each attempt may take PARROTFLOW_PLANNER_TIMEOUT
seconds, and a failed attempt is tried twice more (see `Planner.client`).
PARROTFLOW_PLANNER_LOOP=agent hands the run to `agent.py` instead of a plan;
PARROTFLOW_PLANNER_TRACE is where it writes one JSON line per call.
"""

import asyncio
import json
import os
import re
import time
import urllib.parse
from typing import List, Literal

import openai
from pydantic import BaseModel, ConfigDict

import decider
import runlog as recording

Do = Literal["click", "pick", "type", "write", "key", "scroll"]
MAX_STEPS = 8

SYSTEM = """You plan how to do a task in a macOS app. A program carries out your plan on the user's screen, one step at a time. It finds each target by the words you give for it, among the controls the app shows.

You get the user's request, the app, its front window, the item the user is looking at, and the items on screen as `Role "name"` lines, nearest to the user's gaze first. Names are listed, and what a field holds after `=`. Things inside closed menus or further down a list are not listed.

Each step is one of:
- click: press one button, link, row, tab or checkbox. `target` is its name.
- pick: choose one item in a menu or list that is open, or that the step before opens. `target` is its name.
- type: put a name, a search query, a subject or another short value into a field. `target` is the field, `value` the text.
- write: put the body of a message or comment into its box. `target` is the box, `value` is the text.
- key: press a key or a shortcut. `value` is the chord in plus form, such as "cmd+shift+n", "cmd+alt+l", "cmd+[", "return", "escape", "tab", "down". `target` is "".
- scroll: `target` is the list or pane, `value` is "up" or "down".

Rules:
- "this", "here", "that one", "this email", "this message" mean the item the user is looking at. It is already chosen. Do not add a step to click, select or open it. Start from it.
- `target` is the name only, without the role: for `Button "Reply All"` write Reply All. When a target is in the listed items, name it exactly as listed. When it appears only after a step (a menu item, a dialog button), use the label the app shows.
- Never invent a URL, a date or time option, a menu item or a label you are not sure exists. Put the doubt in `unsure`. To reach a person, channel, page or file by name, prefer the app's search or a lookup field.
- `write` only for the body of a message or comment, and only with what the user asked to say. If the user did not say what it should say, end the plan with a click in that box: the user will dictate it.
- `type` for names, search queries, subjects and field values. Type only words the user said.
- When the step before leaves the caret in the field (a shortcut that opens a search box, a new folder's name), leave `target` empty on the `type` or `write` step.
- One action per step. At most 8 steps.
- Prefer the app's keyboard shortcut when it has one for the step.
- Never select all in a message, a comment or a document, and never replace or delete text there. `write` and `type` add text; they never overwrite.
- Never send, post, delete, archive, leave or pay. If the task ends with one of those, stop just before it.
- `expect` is what should be on screen after the step, in a few words the program can look for: a window title, a field, a menu, a name. Empty when nothing visible changes.
- If this screen already shows the task done, or the app cannot do it, give no steps and say why in `unsure`."""

ADVICE = """

The plan below was started and stalled, or a step opened something the plan does not use. You get the screen as it is now, the steps taken and what each changed, and why it stalled. Give the steps that remain, from this screen. Do not repeat steps that worked. Do not repeat the step that failed the same way: name another target or use another route."""

class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


def strict_schema(model):
    """The model's JSON schema as OpenAI's strict mode takes it: every
    property required, no other properties, no titles or defaults, and the
    nested models written out in place."""
    schema = model.model_json_schema()
    defs = schema.pop("$defs", {})

    def clean(node):
        if isinstance(node, list):
            return [clean(n) for n in node]
        if not isinstance(node, dict):
            return node
        if "$ref" in node:
            return clean(defs[node["$ref"].rsplit("/", 1)[-1]])
        out = {}
        for key, value in node.items():
            if key in ("title", "default"):
                continue
            if key == "properties":
                out[key] = {name: clean(v) for name, v in value.items()}
            else:
                out[key] = clean(value)
        if out.get("type") == "object":
            out["additionalProperties"] = False
            out["required"] = list(out.get("properties", {}))
            out.setdefault("properties", {})
        return out

    schema = clean(schema)
    schema.pop("description", None)
    return schema


class PlanStep(Strict):
    do: Do
    target: str
    value: str
    expect: str


class PlanReply(Strict):
    steps: List[PlanStep]
    unsure: str


SCHEMA = strict_schema(PlanReply)

NAME_CHARS = 60


class Failure(Exception):
    pass


class Plan:
    def __init__(self, steps, unsure, ms, tokens=0):
        self.steps = steps
        self.unsure = unsure
        self.ms = ms
        self.tokens = tokens

    def lines(self):
        out = []
        for i, step in enumerate(self.steps, 1):
            out.append(f"{i}. {describe_step(step)}")
        return out


def describe_step(step):
    said = step["do"]
    if step["target"]:
        said += f" “{step['target']}”"
    if step["value"]:
        said += f" = “{decider.prefix(step['value'], 60)}”"
    if step["expect"]:
        said += f" → {step['expect']}"
    return said


def doing(step):
    """The step as the run panel says it while it runs."""
    do, target, value = step["do"], step["target"], decider.prefix(step["value"], 40)
    if do in ("type", "write"):
        said = f"{'typing' if do == 'type' else 'writing'} “{value}”"
        return said + (f" in {decider.prefix(target, 40)}…" if target else "…")
    if do == "key":
        return f"pressing {value}…"
    if do == "scroll":
        return f"scrolling {value or 'down'}…"
    return f"{'picking' if do == 'pick' else 'clicking'} “{decider.prefix(target, 40)}”…"


_SYMBOLS = {"⌘": "cmd+", "⌥": "alt+", "⇧": "shift+", "⌃": "ctrl+", "↩": "return", "⎋": "escape"}


def chord(value):
    """The plus form Swift reads: ⌘⌥L and "Cmd + L" both become cmd+alt+l."""
    text = value.strip()
    for symbol, word in _SYMBOLS.items():
        text = text.replace(symbol, word)
    parts = [p.strip().lower() for p in text.split("+")]
    if text.endswith("++"):
        parts = [p for p in parts if p] + ["+"]
    else:
        parts = [p for p in parts if p]
    names = {"command": "cmd", "option": "alt", "opt": "alt", "control": "ctrl",
             "enter": "return", "esc": "escape"}
    return "+".join(names.get(p, p) for p in parts)


# Context


def _value(item):
    """` = "16:00"` for a field that holds something other than its name.
    Seen 09-23: the model retyped a time it had set, because the line showed
    only the field's name."""
    if item["kind"] != "text":
        return ""
    value = " ".join((item.get("value") or "").split())
    if not value or value == " ".join(item["name"].split()):
        return ""
    return f" = \"{decider.prefix(value, NAME_CHARS)}\""


def _line(item):
    role = item["role"].replace("AX", "") or "Item"
    name = decider.prefix(" ".join(item["name"].split()), NAME_CHARS)
    notes = [f"in the {item['in']}"] if item.get("in") else []
    notes += item.get("state") or []
    notes = f" ({', '.join(notes)})" if notes else ""
    if name:
        return f"{role} \"{name}\"{_value(item)}{notes}"
    if item["kind"] == "text":
        if item["role"] == "AXComboBox":
            return f"{role} (no name: looks people and channels up as you type){_value(item)}{notes}"
        return f"{role} (no name){_value(item)}{notes}"
    return role + notes


GAZE_CM = 1.5


def gaze_item(snapshot, offers):
    """What "this" is: the nearest clickable or text item, when one is close.
    The snapshot is sorted by distance from the gaze."""
    for item in offers:
        if float(item.get("cm", 0)) > GAZE_CM:
            return None
        if item.get("clickable", item["kind"] in ("click", "text")):
            return item
    return None


_LISTED = re.compile(r'^[A-Za-z]+ "(.+)"$')


def bare_target(target):
    """The planner sometimes copies the whole `Role "name"` line."""
    found = _LISTED.match(target.strip())
    return found.group(1) if found else target.strip()


def context(utterance, snapshot, offers, bundle="", notes=None, looking=None, change=None):
    """The request and what is on screen, as the planner reads it. Names,
    and what a field holds: no message text beyond a row's name. `change` is
    `loop.changes()` of the last step."""
    app = snapshot["app"]
    lines = [f"Request: {utterance}",
             f"App: {app}" + (f" ({bundle})" if bundle else ""),
             f"Window: \"{snapshot['window']}\""]
    looking = looking if looking is not None else gaze_item(snapshot, offers)
    lines.append(f"Looking at: {_line(looking)}" if looking else "Looking at: nothing in particular")
    lines.append("On screen, nearest first:")
    seen = set()
    for item in offers:
        line = _line(item)
        if line in seen:
            continue
        seen.add(line)
        lines.append(f"- {line}")
    change = change or {}
    for part in change.get("appeared", ()):
        near = f" near \"{part['near']}\"" if part.get("near") else ""
        rows = ", ".join(f"\"{decider.prefix(r, NAME_CHARS)}\"" for r in part["rows"][:8])
        lines.append(f"Just opened: a {part['kind']}{near} with {rows}")
    for name, value in change.get("values", {}).items():
        lines.append(f"Now in \"{name}\": \"{decider.prefix(value, 100)}\"")
    if notes:
        lines.append(f"How this app works: {notes}")
    return "\n".join(lines)


def bare_context(utterance, app, bundle=""):
    return "\n".join([f"Request: {utterance}", f"App: {app}" + (f" ({bundle})" if bundle else ""),
                      "Window: unknown", "Looking at: nothing in particular",
                      "On screen: not read"])


def advice(screen, steps_done, why):
    """`steps_done`: (step, outcome) pairs, outcome being what changed or
    why it failed."""
    lines = [screen, "", "Steps taken:"]
    for i, (step, outcome) in enumerate(steps_done, 1):
        lines.append(f"{i}. {describe_step(step)} — {outcome}")
    if not steps_done:
        lines.append("(none)")
    lines.append(f"Stalled: {why}")
    return "\n".join(lines)


# The call


RETRIES = 2
# Arguments `create()` takes by name in openai 1.57.4. The rest, such as
# `reasoning_effort`, goes in the body as given.
NAMED = {"tools", "tool_choice", "parallel_tool_calls", "response_format"}
# httpx2 2.13 calls brotli 1.1's Decompressor.process() with a keyword it
# does not take: every brotli answer failed with a TypeError (09-23).
PLAIN = {"Accept-Encoding": "gzip, deflate"}


def base_url(endpoint):
    """The SDK's base URL: the endpoint without `/chat/completions`. An
    endpoint that does not end with it is taken as the base."""
    parts = urllib.parse.urlsplit(endpoint)
    path = parts.path.rstrip("/")
    if path.endswith("/chat/completions"):
        path = path[:-len("/chat/completions")]
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, path, "", ""))


class Planner:
    def __init__(self, url, key, model, reasoning="none", timeout=15.0, source="",
                 loop="plan", trace=""):
        self.url = urllib.parse.urlsplit(url)
        self.loop = loop
        self.trace = trace
        self.key = key
        self.model = model
        self.reasoning = reasoning
        self.timeout = timeout
        self.source = source
        self.recorder = recording.OFF
        self._client = None
        self._agent_model = None
        self._events = None
        # The last request body the agent's client sent: what the model got.
        # The agent's calls go to /v1/responses; `chat` stays on chat completions.
        self.sent = None

    @classmethod
    def from_env(cls):
        env = os.environ
        model = env.get("PARROTFLOW_PLANNER_MODEL", "").strip()
        key = env.pop("PARROTFLOW_PLANNER_KEY", "").strip()
        if not model:
            return None
        return cls(
            env.get("PARROTFLOW_PLANNER_URL", "https://api.openai.com/v1/chat/completions"),
            key, model, env.get("PARROTFLOW_PLANNER_REASONING", "none"),
            float(env.get("PARROTFLOW_PLANNER_TIMEOUT", "15")),
            env.get("PARROTFLOW_PLANNER_KEY_SOURCE", "no key configured"),
            env.get("PARROTFLOW_PLANNER_LOOP", "plan").strip() or "plan",
            env.get("PARROTFLOW_PLANNER_TRACE", "")
            or os.path.expanduser("~/Library/Logs/ParrotFlow-agent.jsonl"),
        )

    @property
    def host(self):
        return self.url.hostname or ""

    @property
    def client(self):
        """One client per runner, so the connection is kept. The timeout is
        httpx's: connect, write, and each wait for bytes of the answer, per
        attempt. Retried: connection errors, timeouts, 408, 409, 429 and 5xx,
        after about 0.5 s then 1 s, or the server's Retry-After up to 60 s."""
        if self._client is None:
            query = dict(urllib.parse.parse_qsl(self.url.query))
            self._client = openai.OpenAI(
                api_key=self.key, base_url=base_url(urllib.parse.urlunsplit(self.url)),
                timeout=self.timeout, max_retries=RETRIES, default_query=query or None,
                default_headers=PLAIN)
        return self._client

    @property
    def agent_model(self):
        """The agent's model: the same host, key, timeout and retries, on the
        Responses API, through Pydantic AI and the SDK's async client. On
        /v1/chat/completions gpt-6-luna answers 400 to any reasoning effort
        but none when tools are sent (09-23)."""
        if self._agent_model is None:
            from pydantic_ai.models.openai import OpenAIResponsesModel
            from pydantic_ai.providers.openai import OpenAIProvider

            async def keep(request):
                try:
                    self.sent = json.loads(request.content)
                except ValueError:
                    self.sent = None

            query = dict(urllib.parse.parse_qsl(self.url.query))
            client = openai.AsyncOpenAI(
                api_key=self.key, base_url=base_url(urllib.parse.urlunsplit(self.url)),
                timeout=self.timeout, max_retries=RETRIES, default_query=query or None,
                default_headers=PLAIN,
                http_client=openai.DefaultAsyncHttpxClient(event_hooks={"request": [keep]}))
            self._agent_model = OpenAIResponsesModel(
                self.model, provider=OpenAIProvider(openai_client=client))
        return self._agent_model

    def run(self, coroutine):
        """Runs a coroutine on the runner's one event loop: the async client's
        connections belong to it."""
        if self._events is None:
            self._events = asyncio.new_event_loop()
        return self._events.run_until_complete(coroutine)

    def plan(self, screen):
        return self._ask(SYSTEM, screen)

    def advise(self, screen, steps_done, why):
        return self._ask(SYSTEM + ADVICE, advice(screen, steps_done, why))

    def chat(self, messages, **extra):
        """One call, retried by the SDK. (the message that came back, usage, ms)."""
        if not self.key:
            raise Failure(f"No key for the planner — {self.source}.")
        if self.reasoning:
            extra["reasoning_effort"] = self.reasoning
        named = {k: v for k, v in extra.items() if k in NAMED}
        body = {k: v for k, v in extra.items() if k not in NAMED}
        started = time.monotonic()
        try:
            raw = self.client.chat.completions.with_raw_response.create(
                model=self.model, messages=messages, extra_body=body or None, **named)
            data = raw.http_response.content
        except openai.APITimeoutError:
            raise Failure(f"The planner timed out after {RETRIES + 1} tries.")
        except openai.APIStatusError as error:
            raise Failure(self._clean(f"The planner answered {error.status_code}: "
                                      f"{error.response.text[:200]}"))
        except openai.APIConnectionError as error:
            cause = error.__cause__ or error
            raise Failure(self._clean(str(cause) or type(cause).__name__))
        ms = int((time.monotonic() - started) * 1000)
        try:
            top = json.loads(data)
            message = top["choices"][0]["message"]
        except (ValueError, KeyError, IndexError, TypeError):
            raise Failure("The planner's answer could not be read")
        if message.get("refusal"):
            raise Failure(self._clean(f"The planner refused: {message['refusal'][:200]}"))
        return message, top.get("usage") or {}, ms

    def _ask(self, system, user):
        messages = [{"role": "system", "content": system}, {"role": "user", "content": user}]
        began = self.recorder.begin_call(self.recorder.counts["calls"] + 1)
        try:
            message, usage, ms = self.chat(
                messages, response_format={"type": "json_schema", "json_schema": {
                    "name": "plan", "strict": True, "schema": SCHEMA}})
        except Failure as failure:
            self.recorder.call(began, "plan", messages, error=str(failure))
            raise
        self.recorder.call(began, "plan", messages, reply=message.get("content"), ms=ms,
                           usage=usage)
        try:
            answer = PlanReply.model_validate_json(message["content"])
            steps = [s.model_dump() for s in answer.steps][:MAX_STEPS]
            for step in steps:
                for field in ("target", "value", "expect"):
                    step[field] = step[field].strip()
                step["target"] = bare_target(step["target"])
                # An empty write came back twice: "put the caret there" is a click.
                if step["do"] in ("type", "write") and not step["value"]:
                    step["do"] = "click"
                if step["do"] == "key":
                    step["value"] = chord(step["value"] or step["target"])
                    step["target"] = ""
            steps = [s for s in steps if s["do"] != "click" or s["target"]]
            tokens = usage.get("prompt_tokens", 0)
            return Plan(steps, answer.unsure, ms, tokens)
        except (ValueError, KeyError, IndexError, TypeError):
            raise Failure("The planner's answer could not be read")

    def _clean(self, text):
        return text.replace(self.key, "…") if self.key else text
